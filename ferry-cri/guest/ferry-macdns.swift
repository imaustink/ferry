// ferry-macdns: a search-list DNS forwarder for a macOS pod.
//
// macOS mDNSResponder appends search domains only to single-label names, so a
// dotted short name like `svc.namespace` is sent to the default resolver as an
// FQDN and never tried against the cluster search path. This tiny forwarder does
// what macOS won't: ferry-cri points the pod's default resolver at it, and for
// each query it tries the name with each cluster search domain (then bare)
// against CoreDNS, returning the first that answers -- with a synthesized CNAME
// from the asked name to the one that resolved, so the client's answer is for
// exactly what it asked. Everything else (already-qualified and external names)
// falls through to the bare query, which CoreDNS forwards upstream.
//
// argv: ferry-macdns <upstream-ip> <search1> <search2> ...   (UDP 127.0.0.1:53)

import Darwin
import Foundation

let args = CommandLine.arguments
guard args.count >= 2, let upstream = ipv4(args[1]) else {
    FileHandle.standardError.write(Data("usage: ferry-macdns <upstream> [search...]\n".utf8)); exit(2)
}
let searchDomains = Array(args.dropFirst(2))

func ipv4(_ s: String) -> in_addr_t? {
    var a = in_addr(); return inet_pton(AF_INET, s, &a) == 1 ? a.s_addr : nil
}

/// Decode a DNS name at `off` in `msg` (following compression), returning the
/// labels and the offset just past the name in the *wire* (not following ptrs).
@Sendable func readName(_ msg: [UInt8], _ off: Int) -> (labels: [[UInt8]], next: Int) {
    var labels: [[UInt8]] = [], i = off, next = -1, guardN = 0
    while i < msg.count, guardN < 128 {
        guardN += 1
        let len = Int(msg[i])
        if len == 0 { if next < 0 { next = i + 1 }; break }
        if len & 0xc0 == 0xc0 {                       // compression pointer
            if next < 0 { next = i + 2 }
            i = ((len & 0x3f) << 8) | Int(msg[i + 1]); continue
        }
        labels.append(Array(msg[(i + 1) ... (i + len)])); i += len + 1
    }
    return (labels, next < 0 ? i : next)
}

/// Encode labels as a DNS name (no compression).
@Sendable func encodeName(_ labels: [[UInt8]]) -> [UInt8] {
    var out: [UInt8] = []
    for l in labels { out.append(UInt8(l.count)); out += l }
    out.append(0); return out
}

@Sendable func u16(_ m: [UInt8], _ o: Int) -> Int { (Int(m[o]) << 8) | Int(m[o + 1]) }

/// One answer/record fully expanded (no compression), as raw wire bytes ready to
/// append, and the offset past it.
@Sendable func readRecord(_ msg: [UInt8], _ off: Int) -> (wire: [UInt8], next: Int)? {
    let (name, afterName) = readName(msg, off)
    guard afterName + 10 <= msg.count else { return nil }
    let type = u16(msg, afterName), cls = u16(msg, afterName + 2)
    let ttl = Array(msg[(afterName + 4) ... (afterName + 7)])
    let rdlen = u16(msg, afterName + 8)
    let rdStart = afterName + 10
    guard rdStart + rdlen <= msg.count else { return nil }
    var rdata: [UInt8]
    if type == 5 {                                    // CNAME rdata is a name -> expand it
        rdata = encodeName(readName(msg, rdStart).labels)
    } else {
        rdata = Array(msg[rdStart ..< rdStart + rdlen])
    }
    var wire = encodeName(name)
    wire += [UInt8(type >> 8), UInt8(type & 0xff), UInt8(cls >> 8), UInt8(cls & 0xff)]
    wire += ttl
    wire += [UInt8(rdata.count >> 8), UInt8(rdata.count & 0xff)] + rdata
    return (wire, rdStart + rdlen)
}

/// Send `query` (a full DNS message) to CoreDNS and return the reply.
@Sendable func ask(_ query: [UInt8]) -> [UInt8]? {
    let s = socket(AF_INET, SOCK_DGRAM, 0); defer { close(s) }
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var to = sockaddr_in(); to.sin_family = sa_family_t(AF_INET); to.sin_port = UInt16(53).bigEndian; to.sin_addr.s_addr = upstream
    let sent = query.withUnsafeBytes { p in withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, p.baseAddress, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
    guard sent == query.count else { return nil }
    var buf = [UInt8](repeating: 0, count: 65535)
    let n = recv(s, &buf, buf.count, 0)
    return n > 0 ? Array(buf[0 ..< n]) : nil
}

/// Build a query message for `name` from the original query's header/type.
@Sendable func buildQuery(id: [UInt8], name: [[UInt8]], type: Int) -> [UInt8] {
    var m = id + [0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]   // RD set, QDCOUNT 1
    m += encodeName(name)
    m += [UInt8(type >> 8), UInt8(type & 0xff), 0x00, 0x01]   // QTYPE, QCLASS IN
    return m
}

/// The client's resolver query -> our answer.
@Sendable func handle(_ query: [UInt8]) -> [UInt8]? {
    guard query.count >= 12, u16(query, 4) == 1 else { return nil }   // one question
    let id = Array(query[0 ... 1])
    let (qname, afterQ) = readName(query, 12)
    guard afterQ + 4 <= query.count else { return nil }
    let qtype = u16(query, afterQ)
    // Candidates: <name>.<search> for each search domain, then the bare name.
    var candidates: [[[UInt8]]] = searchDomains.map { qname + $0.split(separator: ".").map { Array($0.utf8) } }
    candidates.append(qname)
    for cand in candidates {
        guard let reply = ask(buildQuery(id: id, name: cand, type: qtype)), reply.count >= 12 else { continue }
        let anCount = u16(reply, 6), rcode = reply[3] & 0x0f
        guard rcode == 0, anCount > 0 else { continue }
        // Re-read the reply's answers, expanded.
        let (_, afterName) = readName(reply, 12)
        var off = afterName + 4, records: [[UInt8]] = []
        for _ in 0 ..< anCount { guard let r = readRecord(reply, off) else { break }; records.append(r.wire); off = r.next }
        // If the winner is the bare name, just return the reply as-is.
        if cand == qname { return reply }
        // Else synthesize: question = qname, answer0 = qname CNAME cand, then the records.
        var out = id + [UInt8(0x81), UInt8(0x80)]                       // response, RD, RA
        out += [0x00, 0x01]                                            // QDCOUNT 1
        out += [UInt8((records.count + 1) >> 8), UInt8((records.count + 1) & 0xff)]  // ANCOUNT
        out += [0, 0, 0, 0]                                            // NS/AR 0
        out += encodeName(qname) + [UInt8(qtype >> 8), UInt8(qtype & 0xff), 0x00, 0x01]
        let cnameRD = encodeName(cand)
        out += encodeName(qname) + [0x00, 0x05, 0x00, 0x01, 0, 0, 0, 30]
        out += [UInt8(cnameRD.count >> 8), UInt8(cnameRD.count & 0xff)] + cnameRD
        for r in records { out += r }
        return out
    }
    // Nothing answered: hand back an NXDOMAIN-ish reply for the bare name.
    return ask(buildQuery(id: id, name: qname, type: qtype))
}

// Listen on 127.0.0.1:53 (UDP).
for fd in Int32(3) ..< 256 { close(fd) }
let sock = socket(AF_INET, SOCK_DGRAM, 0)
guard sock >= 0 else { perror("socket"); exit(1) }
var yes: Int32 = 1
setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(53).bigEndian
inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
guard bound == 0 else { perror("bind"); exit(1) }
print("ferry-macdns: 127.0.0.1:53 -> \(args[1]), search \(searchDomains.joined(separator: " "))")

var buf = [UInt8](repeating: 0, count: 65535)
while true {
    var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(sock, &buf, buf.count, 0, $0, &len) } }
    guard n > 0 else { continue }
    let query = Array(buf[0 ..< n])
    Thread {
        guard let answer = handle(query) else { return }
        _ = answer.withUnsafeBytes { p in withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sock, p.baseAddress, answer.count, 0, $0, len) } } }
    }.start()
}
