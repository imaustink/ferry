// Addresses on the cluster pod network.
//
// Every node hands out from its own /24 inside one cluster-wide /16, so two
// nodes never collide and no node has to ask anyone for permission. A pod's
// address carries its node in the third octet, which makes a packet capture
// legible and a routing table unnecessary -- everything is one subnet.

import Foundation

struct RotatingAddresses {
    let prefix: String        // "10.244.7" for node 7 of 10.244.0.0/16
    let prefixLength: Int     // 16: the whole cluster is one segment
    private var next: UInt8 = 2
    private var inUse: Set<UInt8> = []

    init?(clusterCIDR: String, nodeIndex: Int) {
        let parts = clusterCIDR.split(separator: "/")
        guard parts.count == 2, let length = Int(parts[1]) else { return nil }
        let octets = parts[0].split(separator: ".")
        guard octets.count == 4, nodeIndex >= 0, nodeIndex <= 255 else { return nil }
        self.prefix = "\(octets[0]).\(octets[1]).\(nodeIndex)"
        self.prefixLength = length
    }

    /// `.1` is left alone so it reads as a gateway even though there is none,
    /// and `.2` is kept for cluster DNS the way the vmnet path already does.
    mutating func take() -> String? {
        for _ in 0..<253 {
            let candidate = next
            next = next == 254 ? 2 : next + 1
            if !inUse.contains(candidate) {
                inUse.insert(candidate)
                return "\(prefix).\(candidate)/\(prefixLength)"
            }
        }
        return nil
    }

    mutating func takeReserved() -> String? {
        guard !inUse.contains(2) else { return nil }
        inUse.insert(2)
        return "\(prefix).2/\(prefixLength)"
    }

    mutating func give(back address: String) {
        guard let host = address.split(separator: "/").first?.split(separator: ".").last,
              let value = UInt8(host) else { return }
        inUse.remove(value)
    }
}
