// A second NIC per machine, carried by ferry rather than by vmnet.
//
// Milestone 3 measured what one vmnet network can and cannot do. Two machines on
// one network reach each other: node to node is fine. Pod addresses are not:
// with correct routes on both sides, `ip_forward=1`, and a bridge holding
// 10.88.1.1/24, a packet from worker-a to 10.88.1.2 never arrives. vmnet carries
// the addresses it assigned and nothing else.
//
// Mode 1 met this first and answered it by owning the cluster segment: eth0 stays
// on vmnet for the internet, the host and the API server, and eth1 is a datagram
// socket ferry reads and writes. This is that arrangement for machines, and the
// code is ferry-cri's -- SwitchInterface and PodSwitch -- narrowed to what a
// handful of nodes on one Mac needs. If mode 2 outlives this experiment the two
// copies should become one module.

import Containerization
import ContainerizationExtras
import Foundation
import Virtualization

/// A machine's end of ferry's own segment.
struct SwitchInterface: Interface, VZInterface, @unchecked Sendable {
    let ipv4Address: CIDRv4
    let ipv4Gateway: IPv4Address? = nil   // eth0 keeps the default route
    let ipv6Address: CIDRv6? = nil
    let ipv6Gateway: IPv6Address? = nil
    let macAddress: MACAddress?
    let mtu: UInt32 = 1500

    /// ferry's end of the pair: frames the machine sends arrive here.
    let hostFD: Int32
    private let guestSide: FileHandle

    init(address: CIDRv4, mac: MACAddress?) throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw Failure.message("socketpair for the machine switch failed")
        }
        // The receive buffer wants to be several times the send buffer or frames
        // are dropped under load; the attachment's documentation says so.
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

/// One flat segment for every machine's cluster traffic.
///
/// Learn which MAC is behind which port, unicast when that is known, flood when
/// it is not. It never looks above the Ethernet header, so pod addresses,
/// Service traffic and ARP all cross unexamined -- which is the entire point,
/// since examining them is what vmnet does and why this exists.
final class MachineSwitch: @unchecked Sendable {
    private struct Port {
        let name: String
        let fd: Int32
        let source: any DispatchSourceRead
    }

    private let lock = NSLock()
    private var ports: [String: Port] = [:]
    private var macToMachine: [UInt64: String] = [:]
    private let queue = DispatchQueue(label: "ferry.node.switch", attributes: .concurrent)

    func attach(machine: String, fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readFrames(from: machine, fd: fd) }
        lock.lock()
        ports[machine] = Port(name: machine, fd: fd, source: source)
        lock.unlock()
        source.resume()
    }

    func detach(machine: String) {
        lock.lock()
        let port = ports.removeValue(forKey: machine)
        macToMachine = macToMachine.filter { $0.value != machine }
        lock.unlock()
        port?.source.cancel()
    }

    private func readFrames(from machine: String, fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if n <= 0 { return }
            forward(frame: Array(buffer[0..<n]), from: machine)
        }
    }

    /// An Ethernet frame is destination MAC, source MAC, then the rest. Six
    /// bytes each, and nothing else here needs decoding.
    private func forward(frame: [UInt8], from machine: String) {
        guard frame.count >= 14 else { return }
        let destination = mac(frame, at: 0)
        let source = mac(frame, at: 6)

        lock.lock()
        macToMachine[source] = machine
        let target = macToMachine[destination]
        let everyone = ports.values.map { ($0.name, $0.fd) }
        let targetFD = target.flatMap { ports[$0]?.fd }
        lock.unlock()

        // A broadcast or an address not yet learned goes to every other port,
        // which is how ARP finds anyone the first time.
        if let targetFD, destination & 0x0100_0000_0000 == 0 {
            send(frame, to: targetFD)
            return
        }
        for (name, fd) in everyone where name != machine {
            send(frame, to: fd)
        }
    }

    private func send(_ frame: [UInt8], to fd: Int32) {
        _ = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    private func mac(_ frame: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<6 { value = value << 8 | UInt64(frame[offset + i]) }
        return value
    }
}
