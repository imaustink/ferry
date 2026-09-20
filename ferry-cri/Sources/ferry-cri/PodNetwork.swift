// The node's slice of the pod network, created *and released* by ferry.
//
// This exists for one reason: something has to release the vmnet reservation,
// and nothing did. The header is explicit -- "the lifetime of such reservation
// is the same as that of `vmnet_network_ref`. Use `CFRelease()` to release the
// network object" -- but `vmnet_network_create` is `CF_RETURNS_RETAINED` on a
// plain `struct vmnet_network *` typedef rather than an audited CF type, so
// Swift does not manage it, and Containerization's `VmnetNetwork` keeps the
// reference in a struct with no `deinit` and no accessor. The reservation
// therefore outlived every ferry process, and a clean `ferry down` was no
// better than a crash.
//
// That mattered more than it sounds, because of what a reservation does while
// it is alive: a refused `vmnet_network_create` *renews* the reservation it was
// refused by (experiment 22). So a node restarting onto its own slice would ask,
// be refused, renew, and repeat -- a wait that could not succeed however long it
// ran. Releasing on shutdown removes the wait rather than tuning it: there is
// nothing left to wait for.
//
// Interfaces are still Containerization's `VmnetNetwork.Interface`, whose
// `init(reference:)` is public, so the VMs on the other end are configured by
// exactly the same code as before. The only thing ferry takes ownership of is
// the network, and the only reason is to be able to let go of it.

import Foundation
import Containerization
import ContainerizationExtras
import vmnet

final class PodNetwork: @unchecked Sendable {
    /// Not managed by Swift: an OpaquePointer's lifetime is ours to end.
    private let reference: vmnet_network_ref

    /// The subnet vmnet actually gave, read back rather than assumed.
    let subnet: CIDRv4

    /// Addresses handed out, by the id that asked for them, so a pod that goes
    /// away gives its address back.
    private var assigned: [String: UInt32] = [:]
    private var reusable: [UInt32] = []
    private var next: UInt32

    private var released = false
    private let lock = NSLock()

    init(subnet requested: CIDRv4) throws {
        var status: vmnet_return_t = .VMNET_FAILURE
        guard let config = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
            throw RuntimeFailure.unsupported("failed to create vmnet config with status \(status)")
        }
        vmnet_network_configuration_disable_dhcp(config)

        // Spelled the way Containerization spells it, deliberately: the gateway
        // and mask go in as presentation-format strings through inet_pton, and
        // getting the byte order wrong here produces a network on a subnet
        // nobody asked for rather than an error.
        var ga = in_addr()
        inet_pton(AF_INET, requested.gateway.description, &ga)
        var ma = in_addr()
        inet_pton(AF_INET, IPv4Address(requested.prefix.prefixMask32).description, &ma)
        guard vmnet_network_configuration_set_ipv4_subnet(config, &ga, &ma) == .VMNET_SUCCESS else {
            throw RuntimeFailure.invalid("failed to set IPv4 subnet \(requested) for network")
        }

        guard let ref = vmnet_network_create(config, &status), status == .VMNET_SUCCESS else {
            throw RuntimeFailure.unsupported("failed to create vmnet network with status \(status)")
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

        // .1 is the gateway vmnet answers on, so the first thing ferry hands
        // out is .2 -- which is where cluster DNS lands, and what the manifests
        // and every node's resolv.conf already expect.
        self.next = self.subnet.lower.value + 2
    }

    var ipv4Gateway: IPv4Address { subnet.gateway }

    /// An interface on this network, for a pod or for anything else that needs
    /// an address on it.
    func createInterface(_ id: String) throws -> VmnetNetwork.Interface? {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return nil }

        let host: UInt32
        if let existing = assigned[id] {
            host = existing
        } else if let recycled = reusable.popLast() {
            host = recycled
            assigned[id] = host
        } else {
            // The last address is the broadcast address, so stop before it.
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

    func releaseInterface(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let host = assigned.removeValue(forKey: id) else { return }
        reusable.append(host)
    }

    /// Ends the reservation, which is the whole point of this type.
    ///
    /// Idempotent, because shutdown can be reached twice -- a signal handler and
    /// a normal exit -- and releasing an already-released reference is not a
    /// mistake that reports itself, it is a crash somewhere else later.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(reference)).release()
    }
}
