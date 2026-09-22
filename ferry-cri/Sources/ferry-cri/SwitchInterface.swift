// SPIKE (experiments/09-multi-node): a second NIC per pod, carried by ferry.
//
// vmnet gives ferry a kernel datapath, NAT to the internet and a host gateway
// for free, and takes in exchange the thing multi-machine clusters need: it
// rewrites a pod's source address on the way out, and it will not route between
// its own networks. Replacing vmnet outright means owning DHCP, NAT and a
// userspace TCP/IP stack, and it would push pods' internet traffic through
// userspace as well.
//
// A pod VM can have more than one NIC. So eth0 stays on vmnet -- unchanged, fast,
// still the default route -- and eth1 is a plain datagram socket that ferry reads
// and writes. Cluster traffic goes there with real source addresses, and ferry
// can forward those frames anywhere, including to another Mac. Nothing needs
// DHCP or NAT, because eth0 already has them.
//
// This file proves the attachment works. The switch itself is not here.

import Foundation
import Containerization
import ContainerizationExtras
import Virtualization

struct SwitchInterface: Interface, VZInterface, @unchecked Sendable {
    let ipv4Address: CIDRv4
    let ipv4Gateway: IPv4Address? = nil   // eth0 keeps the default route
    let ipv6Address: CIDRv6? = nil
    let ipv6Gateway: IPv6Address? = nil
    let macAddress: MACAddress?
    let mtu: UInt32 = 1500

    /// ferry's end of the pair. Frames the pod sends arrive here, and the
    /// switch forwards them.
    let hostFD: Int32
    private let guestSide: FileHandle

    init(address: CIDRv4, mac: MACAddress?) throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw RuntimeFailure.unsupported("socketpair for the pod switch failed")
        }
        // The attachment documents these: the receive buffer wants to be several
        // times the send buffer or frames are dropped under load.
        var snd: Int32 = 1 * 1024 * 1024
        var rcv: Int32 = 4 * 1024 * 1024
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        }
        self.hostFD = fds[0]
        self.guestSide = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        self.ipv4Address = address
        self.macAddress = mac
    }

    /// Closes the VM's end of the pair, once the VM that used it has stopped.
    /// The host end belongs to the pod switch, which closes it on detach.
    func closeGuestSide() {
        try? guestSide.close()
    }

    func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: guestSide)
        attachment.maximumTransmissionUnit = Int(mtu)
        config.attachment = attachment
        if let macAddress, let vz = VZMACAddress(string: "\(macAddress)") {
            config.macAddress = vz
        }
        return config
    }

}
