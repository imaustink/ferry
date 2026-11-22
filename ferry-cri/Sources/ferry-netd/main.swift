// ferry-netd holds a node's vmnet network for it, so the subnet outlives a
// ferry-cri that dies.
//
// A vmnet subnet is reserved for as long as something holds it. ferry-cri used
// to create and hold its own, and releases it on a clean shutdown, so a clean
// restart gets the same subnet straight back (experiment 22). But a ferry-cri
// that dies uncleanly -- a crash, kill -9, the stop timeout in 'ferry down' --
// leaves its pod VMs' interfaces behind, and vmnet keeps the subnet reserved
// for a while after them. The next start found it taken. Alone, the node moved
// to another subnet, which changes every pod address and rolls CoreDNS; with
// other Macs in the cluster it cannot move, so it waited up to 200 seconds and
// then refused to start.
//
// So the network is created here instead, by a process that has no VMs and so
// nothing to crash with, and handed to ferry-cri as a serialization it
// rehydrates (vmnet_network_create_with_serialization, which is what Apple's
// own container-network-vmnet does for its runtime helpers). While this holds
// it, the subnet is this node's whatever happens to ferry-cri, and a new
// ferry-cri asking for it is given the network rather than asking vmnet to
// create one, so it is never refused (experiments/41-vmnet-owner).
//
// 'ferry down' stops this after a clean ferry-cri shutdown, which releases the
// subnet at once, as before. After an unclean one it is left running for the
// next start to use, which is the case it exists for.
//
//   ferry-netd --socket PATH
//
// One request per connection, one line each way:
//
//   network 10.244.0.1/24            ->  ok <base64 serialization>
//                                    or  refused <vmnet status>
//                                    or  error <message>
//
// After an ok, the connection stays open until the client closes it: it is
// how ferry-cri learns that this process, and with it the network, has gone.
//
// It holds one network. Asked for a different subnet, it creates that one and
// releases the one it had, since a node uses one at a time and the new ask is
// the node's current choice.

import Darwin
import Foundation
import vmnet

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
guard let at = args.firstIndex(of: "--socket"), at + 1 < args.count else {
    FileHandle.standardError.write("usage: ferry-netd --socket PATH\n".data(using: .utf8)!)
    exit(2)
}
let socketPath = args[at + 1]

// Its own session, so it outlives the job that started it. The login agent
// recovers from a crashed ferry-cri by running 'ferry down' and exiting, and
// launchd then ends what is left of that job -- this included, if it shared
// the job's process group. Surviving that is the point of this process.
_ = setsid()

final class Holder: @unchecked Sendable {
    private let lock = NSLock()
    private var network: vmnet_network_ref?
    private var gateway = ""

    /// The serialization of the network for `gateway`/24, creating it if this
    /// does not hold it already.
    func serialization(gateway wanted: String, prefix: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        if network == nil || gateway != wanted {
            var status: vmnet_return_t = .VMNET_FAILURE
            guard let cfg = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
                return "error vmnet configuration: \(status.rawValue)"
            }
            vmnet_network_configuration_disable_dhcp(cfg)
            var ga = in_addr(), ma = in_addr()
            guard inet_pton(AF_INET, wanted, &ga) == 1 else { return "error bad gateway \(wanted)" }
            ma.s_addr = prefix == 0 ? 0 : (UInt32.max << (32 - UInt32(prefix))).bigEndian
            guard vmnet_network_configuration_set_ipv4_subnet(cfg, &ga, &ma) == .VMNET_SUCCESS else {
                return "error vmnet refused subnet \(wanted)/\(prefix)"
            }
            // Asked once per request. A refused create renews the reservation it
            // was refused by (experiment 22), so the spacing of retries is the
            // caller's to decide, as it was when ferry-cri asked vmnet itself.
            guard let created = vmnet_network_create(cfg, &status), status == .VMNET_SUCCESS else {
                return "refused \(status.rawValue)"
            }
            if let old = network { release(old) }
            network = created
            gateway = wanted
            print("holding \(wanted)/\(prefix)")
        }
        var status: vmnet_return_t = .VMNET_FAILURE
        guard let blob = vmnet_network_copy_serialization(network!, &status),
              let inner = xpc_dictionary_get_value(blob, Self.serializationKey),
              let bytes = xpc_data_get_bytes_ptr(inner) else {
            return "error vmnet serialization: \(status.rawValue)"
        }
        return "ok " + Data(bytes: bytes, count: xpc_data_get_length(inner)).base64EncodedString()
    }

    /// The one key of the dictionary vmnet serializes a network to. Sent alone
    /// and wrapped again on the other side, because an XPC object has no public
    /// byte form outside an XPC connection.
    static let serializationKey = "networkSerialization"

    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        if let held = network { release(held); network = nil; print("released \(gateway)") }
    }

    private func release(_ ref: vmnet_network_ref) {
        // vmnet_network_create is CF_RETURNS_RETAINED on a typedef Swift does
        // not manage; see ferry-cri's PodNetwork for the same release.
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ref)).release()
    }
}

let holder = Holder()

// Release and go on SIGTERM. Built from a @Sendable closure in a dispatch
// source on its own queue: a handler with main-actor isolation traps when a
// global queue calls it, which is how ferry-cri's handler never ran for months
// (experiment 22).
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalQueue = DispatchQueue(label: "ferry-netd.signals")
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler { @Sendable in
        holder.releaseAll()
        unlink(socketPath)
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

// The socket: this user's alone, as ferry-cri's are.
unlink(socketPath)
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0 else { perror("socket"); exit(1) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    print("socket path too long: \(socketPath)"); exit(1)
}
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes + [0]) }
let previousUmask = umask(0o177)
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
umask(previousUmask)
guard bound == 0, listen(listener, 8) == 0 else { perror("bind/listen \(socketPath)"); exit(1) }
print("serving \(socketPath)")

/// "network 10.244.0.1/24" -> the reply line.
@Sendable func answer(_ request: String) -> String {
    let parts = request.split(separator: " ")
    guard parts.count == 2, parts[0] == "network" else { return "error unknown request" }
    let cidr = parts[1].split(separator: "/")
    guard cidr.count == 2, let prefix = Int(cidr[1]), (8...30).contains(prefix) else {
        return "error bad subnet \(parts[1])"
    }
    return holder.serialization(gateway: String(cidr[0]), prefix: prefix)
}

Thread.detachNewThread {
    while true {
        let client = accept(listener, nil, nil)
        if client < 0 { continue }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var request = [UInt8]()
        var byte: UInt8 = 0
        while request.count < 256, read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {
            request.append(byte)
        }
        let line = answer(String(decoding: request, as: UTF8.self))
        let reply = Array((line + "\n").utf8)
        _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        guard line.hasPrefix("ok ") else { close(client); continue }
        // Kept open for as long as the client holds the network, so that each
        // can tell when the other has gone. The client cannot outlive this
        // process's network -- a vmnet network ends with the process that
        // created it, whoever else holds a rehydrated copy, and its pods are
        // unreachable from then on while still reporting Ready -- so ferry-cri
        // watches this connection and stops when it closes (experiment 41).
        // Here, it only has to be closed once the client has gone.
        timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        Thread.detachNewThread {
            var sink = [UInt8](repeating: 0, count: 64)
            while true {
                let n = read(client, &sink, sink.count)
                if n > 0 { continue }
                if n < 0 && errno == EINTR { continue }
                break
            }
            close(client)
        }
    }
}

dispatchMain()
