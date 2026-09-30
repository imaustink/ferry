// ClusterIP Services for macOS pods, done host-side.
//
// A Linux ferry pod reaches a Service by loading kube-proxy's nftables rules into
// its own kernel, which DNATs the ClusterIP to a backend pod. A macOS pod has no
// Linux kernel to load them into -- but its cluster traffic leaves en1 and
// arrives here, in ferry-cri's userspace pod switch, as raw Ethernet. So ferry-cri
// is the Service router for a macOS pod: the guest routes the Service CIDR to a
// virtual gateway on en1 that this answers ARP for, and a frame to a ClusterIP is
// rewritten (DNAT) to a chosen endpoint, its checksums fixed, and forwarded on the
// switch; a connection-tracking entry rewrites the endpoint's replies back to the
// ClusterIP so the pod sees the address it dialed.
//
// The Service table comes from the same kube-proxy render ferry-cri already
// fetches for the Linux pods (ferry-proxyd's /ruleset); `parseKubeProxyRuleset`
// reads the ClusterIP -> endpoint mapping out of the nftables text. IPv4, TCP and
// UDP; session affinity, SCTP and NodePorts are not handled (a first cut).

import Foundation

/// A ClusterIP service port: what a pod dials.
struct ServiceKey: Hashable, Sendable {
    let ip: UInt32          // ClusterIP, host byte order
    let proto: UInt8        // IPPROTO_TCP / IPPROTO_UDP
    let port: UInt16
}

/// A backend the ClusterIP is rewritten to.
struct Endpoint: Hashable, Sendable {
    let ip: UInt32          // host byte order
    let port: UInt16
}

/// A ClusterIP service: its backends and, when `sessionAffinity: ClientIP` is
/// set, the window a client sticks to the backend it first hit.
struct Service: Sendable, Equatable {
    var endpoints: [Endpoint]
    var affinityTimeout: TimeInterval?
}

typealias ServiceTable = [ServiceKey: Service]

/// Parses kube-proxy's rendered nftables ruleset into ClusterIP -> endpoints.
///
/// The shape (from `knftables.Fake.Dump()`):
///   add element ip kube-proxy service-ips { 10.96.0.1 . tcp . 443 : goto service-XXXX }
///   add rule ip kube-proxy service-XXXX ... dnat to 10.244.0.5:8080
///   add rule ip kube-proxy service-XXXX ... jump endpoint-YYYY   (multi-endpoint)
///   add rule ip kube-proxy endpoint-YYYY ... dnat to 10.244.0.6:8080
/// so a service chain's endpoints are the `dnat to` targets reachable from it,
/// directly or through the endpoint chains it jumps to.
func parseKubeProxyRuleset(_ text: String) -> ServiceTable {
    // chain -> its own `dnat to` targets, and chain -> chains it jumps/goes to.
    var dnat: [String: [Endpoint]] = [:]
    var jumps: [String: [String]] = [:]
    var serviceOf: [(ServiceKey, String)] = []   // (clusterIP:proto:port, service chain)
    // A service chain that references an `@affinity-*` set has ClientIP session
    // affinity; the set's `timeout <N>s` is the window.
    var affinityChains: Set<String> = []
    var setTimeout: [String: TimeInterval] = [:]

    func endpoint(_ s: Substring) -> Endpoint? {
        // "10.244.0.5:8080"
        guard let colon = s.lastIndex(of: ":"),
              let ip = ipToUInt32(String(s[s.startIndex..<colon])),
              let port = UInt16(s[s.index(after: colon)...]) else { return nil }
        return Endpoint(ip: ip, port: port)
    }

    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let f = line.split(separator: " ")
        // add element ip kube-proxy service-ips { <ip> . <proto> . <port> : goto <chain> }
        if line.hasPrefix("add element ip kube-proxy service-ips {"),
           let braceOpen = f.firstIndex(of: "{"),
           f.count >= braceOpen + 8 {
            let ipTok = f[braceOpen + 1], protoTok = f[braceOpen + 3], portTok = f[braceOpen + 5]
            let verb = f[braceOpen + 7]   // "goto" or "jump"
            if let ip = ipToUInt32(String(ipTok)), let port = UInt16(portTok),
               let proto = protoNumber(String(protoTok)), verb == "goto" || verb == "jump",
               f.count >= braceOpen + 9 {
                serviceOf.append((ServiceKey(ip: ip, proto: proto, port: port), String(f[braceOpen + 8])))
            }
            continue
        }
        // add set ip kube-proxy affinity-... { ... timeout <N>s ; }
        if line.hasPrefix("add set ip kube-proxy affinity-"), f.count >= 5,
           let ti = f.firstIndex(of: "timeout"), ti + 1 < f.count,
           let secs = TimeInterval(f[ti + 1].dropLast()) {   // "10800s" -> 10800
            setTimeout[String(f[4])] = secs
            continue
        }
        // add rule ip kube-proxy <chain> ... (dnat to X:Y | jump/goto <chain> | @affinity-*)
        guard line.hasPrefix("add rule ip kube-proxy "), f.count >= 5 else { continue }
        let chain = String(f[4])
        if let di = f.firstIndex(of: "dnat"), di + 2 < f.count, f[di + 1] == "to",
           let ep = endpoint(f[di + 2]) {
            dnat[chain, default: []].append(ep)
        }
        if f.contains(where: { $0.hasPrefix("@affinity-") }) { affinityChains.insert(chain) }
        for verb in ["jump", "goto"] {
            if let ji = f.firstIndex(of: Substring(verb)), ji + 1 < f.count {
                jumps[chain, default: []].append(String(f[ji + 1]))
            }
        }
    }

    // Resolve each service chain's endpoints (its own dnats + those of chains it
    // reaches), guarding against cycles.
    func resolve(_ chain: String, _ seen: inout Set<String>) -> [Endpoint] {
        guard seen.insert(chain).inserted else { return [] }
        var eps = dnat[chain] ?? []
        for next in jumps[chain] ?? [] { eps += resolve(next, &seen) }
        return eps
    }

    var table: ServiceTable = [:]
    for (key, chain) in serviceOf {
        var seen = Set<String>()
        let eps = resolve(chain, &seen)
        guard !eps.isEmpty else { continue }
        // Affinity timeout: the service is affinity-enabled if its chain (or any
        // chain it reaches) references an @affinity set. Take the first timeout
        // known for those sets (they share one per service).
        var affinity: TimeInterval?
        if affinityChains.contains(chain) {
            var s2 = Set<String>()
            affinity = affinityTimeout(chain, jumps: jumps, setTimeout: setTimeout, seen: &s2) ?? 10800
        }
        table[key] = Service(endpoints: eps, affinityTimeout: affinity)
    }
    return table
}

/// The affinity timeout reachable from a service chain: the affinity sets are
/// named like the endpoint chains, so match a `setTimeout` entry whose name a
/// reached chain matches. Falls back to nil (caller defaults it).
private func affinityTimeout(_ chain: String, jumps: [String: [String]],
                             setTimeout: [String: TimeInterval], seen: inout Set<String>) -> TimeInterval? {
    guard seen.insert(chain).inserted else { return nil }
    // The affinity set for endpoint-<hash>-<svc>/... is affinity-<hash>-<svc>/...
    if chain.hasPrefix("endpoint-"), let t = setTimeout["affinity-" + chain.dropFirst("endpoint-".count)] {
        return t
    }
    for next in jumps[chain] ?? [] {
        if let t = affinityTimeout(next, jumps: jumps, setTimeout: setTimeout, seen: &seen) { return t }
    }
    return nil
}

/// The host-side Service router for one macOS pod's switch port. Not an actor: it
/// is called from the pod switch's frame path (its own concurrent queue) and
/// guards its mutable state with a lock, like the switch itself.
final class MacServiceNAT: @unchecked Sendable {
    private let lock = NSLock()
    private var table: ServiceTable = [:]

    /// The pod this NAT serves.
    private let podIP: UInt32
    /// The virtual gateway the guest routes the Service CIDR to; this answers ARP
    /// for it and receives the Service frames addressed to its MAC.
    private let gatewayIP: UInt32
    private let gatewayMAC: [UInt8]     // 6 bytes

    /// Connection tracking: an egress DNAT records how to reverse the endpoint's
    /// replies. Keyed by the reverse 5-tuple (endpoint -> pod) so a returning
    /// frame is matched in O(1). Value carries the ClusterIP:port to restore and
    /// a last-touched time for expiry.
    private struct Reverse { let clusterIP: UInt32; let clusterPort: UInt16; var seen: Date }
    private var conntrack: [ConnKey: Reverse] = [:]
    /// Which endpoint a live connection already chose, so its later packets keep
    /// going to the same backend.
    private var forward: [ConnKey: Endpoint] = [:]
    private var rr: [ServiceKey: Int] = [:]     // round-robin cursor per service
    private var lastSweep = Date()
    /// ClientIP session affinity: a client's chosen backend per service, so new
    /// connections from the same client keep hitting it within the window.
    private struct AffinityKey: Hashable { let svc: ServiceKey; let client: UInt32 }
    private var affinity: [AffinityKey: (ep: Endpoint, seen: Date)] = [:]

    struct ConnKey: Hashable { let proto: UInt8; let aIP: UInt32; let aPort: UInt16; let bIP: UInt32; let bPort: UInt16 }

    init(podIP: UInt32, gatewayIP: UInt32, gatewayMAC: [UInt8]) {
        self.podIP = podIP
        self.gatewayIP = gatewayIP
        self.gatewayMAC = gatewayMAC
    }

    /// The virtual gateway, so the switch can ARP a backend on its behalf when it
    /// needs the backend's MAC to unicast a DNATed frame.
    var gwIP: UInt32 { gatewayIP }
    var gwMAC: [UInt8] { gatewayMAC }

    func update(_ table: ServiceTable) {
        lock.lock(); self.table = table; lock.unlock()
    }

    /// What the switch should do with a frame the pod just sent.
    enum Egress {
        case pass                 // not ours; forward normally
        case reply(Data)          // send this back to the pod (ARP reply)
        case forward(Data)        // forward this rewritten frame on the switch
        case drop
    }

    /// Handle a frame egressing from the pod. Answers ARP for the gateway and
    /// DNATs frames addressed to the gateway MAC whose destination is a ClusterIP.
    func egress(_ frame: Data) -> Egress {
        guard frame.count >= 14 else { return .pass }
        let ethertype = u16(frame, 12)
        if ethertype == 0x0806 { // ARP
            if let reply = arpReply(frame) { return .reply(reply) }
            return .pass
        }
        guard ethertype == 0x0800 else { return .pass }
        // Only frames sent to the virtual gateway are Service traffic; pod-to-pod
        // goes straight to the peer's MAC and must pass through untouched.
        guard macBytes(frame, 0) == gatewayMAC else { return .pass }
        guard frame.count >= 34 else { return .drop }
        let ihl = Int(frame[14] & 0x0f) * 4
        let proto = frame[23]
        // TCP, UDP and SCTP all carry src/dst port in the first four L4 bytes.
        guard proto == 6 || proto == 17 || proto == 132, frame.count >= 14 + ihl + 4 else { return .drop }
        let l4 = 14 + ihl
        let srcIP = u32(frame, 26), dstIP = u32(frame, 30)
        let srcPort = u16(frame, l4), dstPort = u16(frame, l4 + 2)
        let key = ServiceKey(ip: dstIP, proto: proto, port: dstPort)
        // pick / recall the endpoint for this connection
        let connFwd = ConnKey(proto: proto, aIP: srcIP, aPort: srcPort, bIP: dstIP, bPort: dstPort)
        lock.lock()
        sweepLocked()
        var chosen = forward[connFwd]
        if chosen == nil, let svc = table[key], !svc.endpoints.isEmpty {
            let now = Date()
            let affKey = AffinityKey(svc: key, client: srcIP)
            if let timeout = svc.affinityTimeout, let a = affinity[affKey],
               now.timeIntervalSince(a.seen) < timeout {
                chosen = a.ep                                   // stick to the client's backend
            } else {
                let i = (rr[key] ?? 0) % svc.endpoints.count    // else round-robin
                rr[key] = i + 1
                chosen = svc.endpoints[i]
            }
            forward[connFwd] = chosen
            if svc.affinityTimeout != nil, let ep = chosen { affinity[affKey] = (ep, now) }
        }
        if let ep = chosen {
            // Record the reverse so the endpoint's replies restore the ClusterIP.
            let rev = ConnKey(proto: proto, aIP: ep.ip, aPort: ep.port, bIP: srcIP, bPort: srcPort)
            conntrack[rev] = Reverse(clusterIP: dstIP, clusterPort: dstPort, seen: Date())
            lock.unlock()
            var out = frame
            rewrite(&out, ihl: ihl, setDstIP: ep.ip, setDstPort: ep.port)
            // Flood on the switch: dst MAC broadcast so it reaches the endpoint
            // wherever it is (this Mac or a peer) without resolving its MAC. The
            // src MAC stays the pod's, so the endpoint replies to the pod.
            setMAC(&out, 0, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
            return .forward(out)
        }
        lock.unlock()
        return .drop     // a ClusterIP with no endpoints: drop, as kube-proxy rejects
    }

    /// Rewrite an endpoint's reply back to the ClusterIP before it reaches the
    /// pod. Returns the (possibly rewritten) frame to deliver.
    func ingress(_ frame: Data) -> Data {
        guard frame.count >= 34, u16(frame, 12) == 0x0800 else { return frame }
        let ihl = Int(frame[14] & 0x0f) * 4
        let proto = frame[23]
        guard proto == 6 || proto == 17 || proto == 132, frame.count >= 14 + ihl + 4 else { return frame }
        let srcIP = u32(frame, 26), dstIP = u32(frame, 30)
        let l4 = 14 + ihl
        let key = ConnKey(proto: proto, aIP: srcIP, aPort: u16(frame, l4),
                          bIP: dstIP, bPort: u16(frame, l4 + 2))
        lock.lock()
        guard var rev = conntrack[key] else { lock.unlock(); return frame }
        rev.seen = Date(); conntrack[key] = rev
        lock.unlock()
        var out = frame
        rewrite(&out, ihl: ihl, setSrcIP: rev.clusterIP, setSrcPort: rev.clusterPort)
        return out
    }

    // MARK: - rewriting

    /// DNAT/un-DNAT: change dst or src IP/port and fix the IP and L4 checksums.
    private func rewrite(_ f: inout Data, ihl: Int,
                         setDstIP dip: UInt32? = nil, setDstPort dport: UInt16? = nil,
                         setSrcIP sip: UInt32? = nil, setSrcPort sport: UInt16? = nil) {
        let l4 = 14 + ihl
        let proto = f[23]
        var ipDelta: [(UInt16, UInt16)] = []
        var l4Delta: [(UInt16, UInt16)] = []
        var portChanged = false

        if let dip {
            let old = u32(f, 30)
            put32(&f, 30, dip)
            ipDelta += words32(old, dip)
            l4Delta += words32(old, dip)     // dst IP is in the TCP/UDP pseudo-header
        }
        if let sip {
            let old = u32(f, 26)
            put32(&f, 26, sip)
            ipDelta += words32(old, sip)
            l4Delta += words32(old, sip)
        }
        if let dport {
            let old = u16(f, l4 + 2)
            put16(&f, l4 + 2, dport)
            l4Delta.append((old, dport)); portChanged = portChanged || old != dport
        }
        if let sport {
            let old = u16(f, l4)
            put16(&f, l4, sport)
            l4Delta.append((old, sport)); portChanged = portChanged || old != sport
        }
        // IP header checksum
        if !ipDelta.isEmpty {
            put16(&f, 24, adjust(u16(f, 24), ipDelta))
        }
        if proto == 132 {
            // SCTP: a CRC32c over the whole SCTP packet, no IP pseudo-header, so
            // address changes don't touch it -- only a port change does, and then
            // the whole CRC is recomputed.
            if portChanged { sctpRecompute(&f, l4: l4) }
            return
        }
        // TCP/UDP checksum (UDP checksum 0 means "not computed" -- leave it alone)
        let l4ckOff = proto == 6 ? l4 + 16 : l4 + 6
        if !l4Delta.isEmpty, l4ckOff + 2 <= f.count {
            let ck = u16(f, l4ckOff)
            if !(proto == 17 && ck == 0) {
                put16(&f, l4ckOff, adjust(ck, l4Delta))
            }
        }
    }

    /// Recompute an SCTP packet's CRC32c (checksum field zeroed during the
    /// computation), stored little-endian at the SCTP common header + 8.
    private func sctpRecompute(_ f: inout Data, l4: Int) {
        guard l4 + 12 <= f.count else { return }
        for i in 0..<4 { f[f.startIndex + l4 + 8 + i] = 0 }
        let crc = crc32c(f, from: l4, to: f.count)
        // SCTP stores the CRC little-endian.
        f[f.startIndex + l4 + 8] = UInt8(crc & 0xff)
        f[f.startIndex + l4 + 9] = UInt8((crc >> 8) & 0xff)
        f[f.startIndex + l4 + 10] = UInt8((crc >> 16) & 0xff)
        f[f.startIndex + l4 + 11] = UInt8((crc >> 24) & 0xff)
    }

    /// CRC32c (Castagnoli), reflected, as SCTP (RFC 3309) uses it.
    private func crc32c(_ d: Data, from: Int, to: Int) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for i in from..<to {
            crc ^= UInt32(d[d.startIndex + i])
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x82f6_3b78 : crc >> 1
            }
        }
        return crc ^ 0xffff_ffff
    }

    /// RFC 1624 incremental checksum update for a set of 16-bit word changes.
    private func adjust(_ checksum: UInt16, _ changes: [(UInt16, UInt16)]) -> UInt16 {
        var sum = UInt32(~checksum & 0xffff)
        for (old, new) in changes {
            sum += UInt32(~old & 0xffff)
            sum += UInt32(new)
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }

    private func words32(_ old: UInt32, _ new: UInt32) -> [(UInt16, UInt16)] {
        [(UInt16(old >> 16), UInt16(new >> 16)), (UInt16(old & 0xffff), UInt16(new & 0xffff))]
    }

    // MARK: - ARP

    /// Answer an ARP request for the gateway with the gateway MAC.
    private func arpReply(_ f: Data) -> Data? {
        guard f.count >= 42 else { return nil }
        guard u16(f, 20) == 1 else { return nil }         // operation: request
        let targetIP = u32(f, 38)
        guard targetIP == gatewayIP else { return nil }
        let senderMAC = macBytes(f, 22)
        let senderIP = u32(f, 28)
        var r = Data(count: 42)
        // Ethernet: to the asker, from the gateway
        for i in 0..<6 { r[i] = senderMAC[i]; r[6 + i] = gatewayMAC[i] }
        r[12] = 0x08; r[13] = 0x06
        // ARP reply
        r[14] = 0x00; r[15] = 0x01; r[16] = 0x08; r[17] = 0x00
        r[18] = 6; r[19] = 4; r[20] = 0x00; r[21] = 0x02
        for i in 0..<6 { r[22 + i] = gatewayMAC[i] }       // sender = gateway
        put32(&r, 28, gatewayIP)
        for i in 0..<6 { r[32 + i] = senderMAC[i] }        // target = asker
        put32(&r, 38, senderIP)
        return r
    }

    // MARK: - conntrack sweep

    private func sweepLocked() {
        let now = Date()
        guard now.timeIntervalSince(lastSweep) > 60 else { return }
        lastSweep = now
        conntrack = conntrack.filter { now.timeIntervalSince($0.value.seen) < 300 }
        // Affinity entries expire on their own (checked against each service's
        // timeout on use); sweep the stalest so the table cannot grow unbounded.
        affinity = affinity.filter { now.timeIntervalSince($0.value.seen) < 10800 }
        // forward/rr are bounded by live services; drop forward entries older than
        // conntrack's window by clearing those with no reverse still live is hard
        // without back-refs, so cap the table instead.
        if forward.count > 4096 { forward.removeAll(); rr.removeAll() }
    }

    // MARK: - byte helpers

    private func u16(_ d: Data, _ o: Int) -> UInt16 { (UInt16(d[d.startIndex + o]) << 8) | UInt16(d[d.startIndex + o + 1]) }
    private func u32(_ d: Data, _ o: Int) -> UInt32 {
        (UInt32(d[d.startIndex + o]) << 24) | (UInt32(d[d.startIndex + o + 1]) << 16)
            | (UInt32(d[d.startIndex + o + 2]) << 8) | UInt32(d[d.startIndex + o + 3])
    }
    private func put16(_ d: inout Data, _ o: Int, _ v: UInt16) {
        d[d.startIndex + o] = UInt8(v >> 8); d[d.startIndex + o + 1] = UInt8(v & 0xff)
    }
    private func put32(_ d: inout Data, _ o: Int, _ v: UInt32) {
        d[d.startIndex + o] = UInt8(v >> 24); d[d.startIndex + o + 1] = UInt8((v >> 16) & 0xff)
        d[d.startIndex + o + 2] = UInt8((v >> 8) & 0xff); d[d.startIndex + o + 3] = UInt8(v & 0xff)
    }
    private func macBytes(_ d: Data, _ o: Int) -> [UInt8] { (0..<6).map { d[d.startIndex + o + $0] } }
    private func setMAC(_ d: inout Data, _ o: Int, _ m: [UInt8]) { for i in 0..<6 { d[d.startIndex + o + i] = m[i] } }
}

// MARK: - address helpers (host byte order)

func ipToUInt32(_ s: String) -> UInt32? {
    let p = s.split(separator: ".")
    guard p.count == 4 else { return nil }
    var v: UInt32 = 0
    for part in p { guard let b = UInt8(part) else { return nil }; v = (v << 8) | UInt32(b) }
    return v
}

func protoNumber(_ s: String) -> UInt8? {
    switch s.lowercased() { case "tcp": return 6; case "udp": return 17; case "sctp": return 132; default: return nil }
}

func dottedIP(_ v: UInt32) -> String {
    "\(v >> 24).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
}
