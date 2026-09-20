// Machines on ferry's pod network, so the two modes can reach each other.
//
// Mode 1's pods sit on one flat layer-2 segment spanning every node and every
// Mac -- `ferry-cri`'s PodSwitch -- and each pod treats the whole cluster CIDR
// as on-link there, ARPing for anything it wants rather than routing to it.
// Machines were not on that segment. They have their own vmnet network, vmnet
// refuses to route between its networks (experiment 09), and the Mac being on
// both does not help because the drop happens inside vmnet rather than in the
// routing table. So a pod in a machine and a pod on the Mac had no path between
// them, which is what kept mode 1 and mode 2 two clusters wearing one name.
//
// This is the machines' end of that segment. It is deliberately not a second
// PodSwitch: the learning, the flooding and the fan-out to other Macs all
// already exist over there, and a second copy of that logic is a second place
// for it to be subtly wrong. What lives here is the smallest thing that cannot
// be borrowed -- which machine a frame belongs to -- and everything else is
// handed to ferry-cri over the relay protocol it already speaks to its peers.
//
// So this switch knows two things. Frames from a machine go to another machine
// if it has seen that address behind one, and to ferry-cri otherwise, which is
// also what happens for broadcast. Frames from ferry-cri go to the machine that
// owns the destination, or to all of them when it has not been learned yet. It
// never sends a frame from ferry-cri back to ferry-cri, because two switches
// that flood to each other trade a broadcast forever.

import Foundation
import Virtualization

final class MachineSwitch: @unchecked Sendable {
    /// A machine's port: ferry's end of the socketpair whose other end is the
    /// machine's second NIC.
    private struct Port {
        let name: String
        let fd: Int32
        let source: any DispatchSourceRead
    }

    private let lock = NSLock()
    private var ports: [String: Port] = [:]
    private var macToMachine: [UInt64: String] = [:]
    /// Addresses last seen arriving from ferry-cri: mode 1's pods, and pods on
    /// other Macs. Without this every frame for a pod outside the machines
    /// floods to all of them before being relayed -- correct, but it makes each
    /// machine carry every other machine's outbound cluster traffic.
    private var remote: Set<UInt64> = []
    private let queue = DispatchQueue(label: "ferry.node.switch", attributes: .concurrent)

    /// ferry-cri's relay, as host:port. Everything not destined for a machine on
    /// this Mac goes here, including traffic for pods on another Mac -- that
    /// onward hop is ferry-cri's to make, and it already knows how.
    private let peer: String
    private var relay: Int32 = -1
    private let relayPort: UInt16

    private(set) var framesLocal = 0
    private(set) var framesRelayed = 0

    init?(relayPort: UInt16, peer: String) {
        guard relayPort > 0, !peer.isEmpty else { return nil }
        self.relayPort = relayPort
        self.peer = peer
        guard startRelay() else { return nil }
    }

    // MARK: - ports

    func attach(name: String, fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let port = Port(name: name, fd: fd, source: source)
        source.setEventHandler { [weak self] in self?.readFrames(from: port) }
        lock.lock()
        ports[name] = port
        lock.unlock()
        source.resume()
    }

    func detach(name: String) {
        lock.lock()
        let port = ports.removeValue(forKey: name)
        // Addresses learned behind a machine that is gone would otherwise send
        // its traffic into a closed descriptor until something else claimed the
        // same MAC, which on a cluster that replaces machines is a while.
        macToMachine = macToMachine.filter { $0.value != name }
        lock.unlock()
        guard let port else { return }
        port.source.cancel()
        close(port.fd)
    }

    // MARK: - forwarding

    private func readFrames(from port: Port) {
        var buffer = [UInt8](repeating: 0, count: 65_550)
        while true {
            let n = recv(port.fd, &buffer, buffer.count, MSG_DONTWAIT)
            if n <= 0 { return }
            guard n >= 14 else { continue }
            let frame = Data(buffer[0..<n])
            learn(source: mac(frame, at: 6), from: port.name)
            deliver(frame, destination: mac(frame, at: 0), from: port.name)
        }
    }

    /// From a machine: to another machine when known, to ferry-cri otherwise.
    private func deliver(_ frame: Data, destination: UInt64, from origin: String?) {
        let isFlood = destination == 0xffff_ffff_ffff || (frame[0] & 0x01) == 1

        lock.lock()
        let target = isFlood ? nil : macToMachine[destination]
        let isRemote = isFlood ? false : remote.contains(destination)
        let all = Array(ports.values)
        lock.unlock()

        if let target, let port = all.first(where: { $0.name == target }) {
            write(frame, to: port.fd)
            lock.lock(); framesLocal += 1; lock.unlock()
            return
        }
        // Known to be on the other side: hand it straight over rather than
        // showing it to every machine first.
        if isRemote {
            relayFrame(frame)
            return
        }

        // Unknown or broadcast. Every machine but the one it came from, and
        // ferry-cri -- which floods it on to the pods and the other Macs.
        for port in all where port.name != origin {
            write(frame, to: port.fd)
        }
        if origin != nil {
            relayFrame(frame)
        }
    }

    /// From ferry-cri: to the machine that owns the address, or to all of them.
    /// Never back to ferry-cri.
    private func deliverFromPeer(_ frame: Data, destination: UInt64) {
        let isFlood = destination == 0xffff_ffff_ffff || (frame[0] & 0x01) == 1

        lock.lock()
        let target = isFlood ? nil : macToMachine[destination]
        let all = Array(ports.values)
        lock.unlock()

        if let target, let port = all.first(where: { $0.name == target }) {
            write(frame, to: port.fd)
            lock.lock(); framesLocal += 1; lock.unlock()
            return
        }
        for port in all { write(frame, to: port.fd) }
    }

    private func learn(source: UInt64, from name: String) {
        guard source != 0, source & 0x01 == 0 else { return }
        lock.lock()
        if macToMachine[source] != name { macToMachine[source] = name }
        remote.remove(source)
        lock.unlock()
    }

    /// A machine that moved -- or a MAC that was behind ferry-cri and is now
    /// local -- is corrected by whichever side sees it next, because learning on
    /// one side removes it from the other.
    private func learnRemote(source: UInt64) {
        guard source != 0, source & 0x01 == 0 else { return }
        lock.lock()
        remote.insert(source)
        macToMachine.removeValue(forKey: source)
        lock.unlock()
    }

    private func write(_ frame: Data, to fd: Int32) {
        _ = frame.withUnsafeBytes { raw in
            send(fd, raw.baseAddress, raw.count, 0)
        }
    }

    private func mac(_ frame: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<6 { value = (value << 8) | UInt64(frame[frame.startIndex + offset + i]) }
        return value
    }

    // MARK: - the relay to ferry-cri

    private func startRelay() -> Bool {
        relay = socket(AF_INET, SOCK_DGRAM, 0)
        guard relay >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(relay, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var size: Int32 = 4 * 1024 * 1024
        setsockopt(relay, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = relayPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(relay, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            FileHandle.standardError.write(
                "machine switch: could not bind udp/\(relayPort)\n".data(using: .utf8)!)
            close(relay); relay = -1; return false
        }
        Thread.detachNewThread { [weak self] in self?.relayLoop() }
        return true
    }

    private func relayLoop() {
        var buffer = [UInt8](repeating: 0, count: 65_550)
        while relay >= 0 {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(relay, &buffer, buffer.count, 0, $0, &len)
                }
            }
            guard n >= 14 else { continue }
            let frame = Data(buffer[0..<n])
            learnRemote(source: mac(frame, at: 6))
            deliverFromPeer(frame, destination: mac(frame, at: 0))
        }
    }

    private func relayFrame(_ frame: Data) {
        guard relay >= 0 else { return }
        let parts = peer.split(separator: ":")
        guard let host = parts.first, let port = parts.last.flatMap({ UInt16($0) }) else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, String(host), &addr.sin_addr)
        _ = frame.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(relay, raw.baseAddress, raw.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        lock.lock(); framesRelayed += 1; lock.unlock()
    }
}

/// A machine's second NIC: ferry holds one end of a datagram socketpair and the
/// machine gets the other, exactly as a pod's switch NIC works in ferry-cri.
///
/// It carries no address of its own here. The guest gives eth1 the machine's own
/// pod-network address with the cluster prefix once the API server has told it
/// which slice it owns, which cannot be known at boot.
struct MachineNIC {
    let hostFD: Int32
    private let guestSide: FileHandle

    init() throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw Failure.message("socketpair for the machine switch failed")
        }
        // The receive buffer wants to be several times the send buffer or frames
        // are dropped under load; VZFileHandleNetworkDeviceAttachment documents
        // this, and ferry-cri's pod NIC sets the same pair.
        var snd: Int32 = 1 * 1024 * 1024
        var rcv: Int32 = 4 * 1024 * 1024
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        }
        self.hostFD = fds[0]
        self.guestSide = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
    }

    func device() -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: guestSide)
        attachment.maximumTransmissionUnit = 1500
        config.attachment = attachment
        return config
    }
}
