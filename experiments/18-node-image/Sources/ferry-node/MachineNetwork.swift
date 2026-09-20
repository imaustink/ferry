// The machines' network, created *and released* by ferry.
//
// The same arrangement, and the same reasons, as ferry-cri's `PodNetwork` --
// see the comment there and experiment 22. In short: a vmnet reservation lives
// as long as its `vmnet_network_ref`, nothing in Containerization releases it,
// and a refused create renews the reservation it was refused by. Left alone,
// that makes `ferry machines disable` followed by `ferry machines enable` wait
// for a subnet ferry itself abandoned, and makes retrying the worst thing to do
// about it.
//
// Interfaces are still Containerization's `VmnetNetwork.Interface`, so the
// machines on the other end are configured by exactly the same code as before.

import Containerization
import ContainerizationExtras
import Foundation
import vmnet

final class MachineNetwork: @unchecked Sendable {
    /// Not managed by Swift: an OpaquePointer's lifetime is ours to end.
    private let reference: vmnet_network_ref

    /// The subnet vmnet actually gave, read back rather than assumed.
    let subnet: CIDRv4

    private var assigned: [String: UInt32] = [:]
    private var reusable: [UInt32] = []
    private var next: UInt32

    private var released = false
    private let lock = NSLock()

    init(subnet requested: CIDRv4?) throws {
        var status: vmnet_return_t = .VMNET_FAILURE
        guard let config = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
            throw Failure.message("failed to create vmnet config with status \(status)")
        }
        vmnet_network_configuration_disable_dhcp(config)

        if let requested {
            var ga = in_addr()
            inet_pton(AF_INET, requested.gateway.description, &ga)
            var ma = in_addr()
            inet_pton(AF_INET, IPv4Address(requested.prefix.prefixMask32).description, &ma)
            guard vmnet_network_configuration_set_ipv4_subnet(config, &ga, &ma) == .VMNET_SUCCESS else {
                throw Failure.message("failed to set IPv4 subnet \(requested) for network")
            }
        }

        guard let ref = vmnet_network_create(config, &status), status == .VMNET_SUCCESS else {
            throw Failure.message("failed to create vmnet network with status \(status)")
        }
        self.reference = ref

        var got = in_addr()
        var mask = in_addr()
        vmnet_network_get_ipv4_subnet(ref, &got, &mask)
        let base = UInt32(bigEndian: got.s_addr)
        let maskValue = UInt32(bigEndian: mask.s_addr)
        let lower = IPv4Address(base & maskValue)
        let upper = IPv4Address(lower.value + ~maskValue)
        self.subnet = try CIDRv4(lower: lower, upper: upper)
        // .1 is the gateway; machines start at .2.
        self.next = self.subnet.lower.value + 2
    }

    var ipv4Gateway: IPv4Address { subnet.gateway }

    func createInterface(_ id: String) throws -> VmnetNetwork.Interface? {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return nil }

        let host: UInt32
        if let existing = assigned[id] {
            host = existing
        } else if !reusable.isEmpty {
            // Oldest first, rather than the address freed most recently. The
            // provisioner replaces machines constantly, and handing the address
            // of the machine that just went away to the machine taking its
            // place means the neighbour caches that still hold it are wrong
            // about a live host rather than about a dead one.
            host = reusable.removeFirst()
            assigned[id] = host
        } else {
            guard next < subnet.upper.value else { return nil }
            host = next
            next += 1
            assigned[id] = host
        }

        return VmnetNetwork.Interface(
            reference: reference,
            ipv4Address: try CIDRv4(IPv4Address(host), prefix: subnet.prefix),
            ipv4Gateway: subnet.gateway)
    }

    /// Gives an address back, so the next machine can have it.
    ///
    /// Not optional bookkeeping: `next` only ever climbs, so without this a /24
    /// is exhausted after roughly 252 machines and every boot after that fails
    /// with "vmnet gave no interface". One long-lived process plus a
    /// provisioner that makes a machine per pending pod and consolidates it
    /// away a minute later reaches that in an afternoon.
    func releaseInterface(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let host = assigned.removeValue(forKey: id) else { return }
        reusable.append(host)
    }

    /// Ends the reservation. Idempotent: shutdown can be reached more than once,
    /// and an over-release is a crash somewhere else later rather than an error
    /// here.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(reference)).release()
    }
}

/// Runs `body` on SIGTERM or SIGINT, off the main queue.
///
/// Taken as a `@Sendable` parameter of a function declared here rather than
/// written inline in `main.swift`, and that is load bearing: top-level code is
/// `@MainActor`-isolated, a dispatch signal source calls its handler on the
/// queue it was given, and Swift traps on the isolation check. ferry-cri lost
/// years of clean shutdowns to exactly that -- see Shutdown.swift over there.
func onShutdownSignal(_ body: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    return [SIGTERM, SIGINT].map { sig in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler(handler: body)
        source.resume()
        return source
    }
}

/// stdout is a log file here, so it is block-buffered: a line printed on the way
/// out is lost unless it is flushed.
func announce(_ message: String) {
    print(message)
    fflush(stdout)
}
