// ferry's pod network: one flat layer-2 segment spanning every node, on every
// machine.
//
// vmnet cannot carry this. It isolates its own networks from each other, and it
// rewrites a pod's source address the moment traffic leaves one -- measured on
// two Macs, a pod reaching another machine arrives as the host. Kubernetes
// requires pod-to-pod traffic to keep its source address, so the cluster network
// has to be something ferry owns.
//
// It does not have to be everything ferry owns. Each pod keeps its vmnet NIC as
// eth0 for the internet and the host, which is fast, already works, and comes
// with NAT and a gateway for free. eth1 is a datagram socket per pod, and this
// is the switch between those sockets: learn which MAC is behind which port,
// unicast when that is known, flood when it is not, and hand frames for other
// machines to a peer over UDP.
//
// Because every pod sits in one /16, no pod needs a route or a gateway for
// cluster traffic -- its peers are all "on the wire", wherever they physically
// are. The switch never looks above the Ethernet header.

import Foundation

final class PodSwitch: @unchecked Sendable {
    /// A pod's port on the switch.
    private struct Port {
        let podID: String
        let fd: Int32
        let source: any DispatchSourceRead
    }

    private let lock = NSLock()
    private var ports: [String: Port] = [:]          // podID -> port
    private var macToPod: [UInt64: String] = [:]     // learned, local
    private var macToPeer: [UInt64: String] = [:]    // learned, remote
    private var peers: Set<String> = []              // host:port of other machines
    private let queue = DispatchQueue(label: "ferry.switch", attributes: .concurrent)

    /// The UDP socket carrying frames to and from other machines.
    private var relay: Int32 = -1
    private let relayPort: UInt16

    /// Frames seen, for `ferry status`.
    private(set) var framesLocal = 0
    private(set) var framesRelayed = 0

    init(relayPort: UInt16, peers: [String]) {
        self.relayPort = relayPort
        self.peers = Set(peers)
        if relayPort > 0 { startRelay() }
    }

    // MARK: - Ports

    func attach(podID: String, fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let port = Port(podID: podID, fd: fd, source: source)
        source.setEventHandler { [weak self] in self?.readFrames(from: port) }
        lock.lock(); ports[podID] = port; lock.unlock()
        source.resume()
    }

    func detach(podID: String) {
        lock.lock()
        let port = ports.removeValue(forKey: podID)
        macToPod = macToPod.filter { $0.value != podID }
        lock.unlock()
        port?.source.cancel()
    }

    // MARK: - Forwarding

    private func readFrames(from port: Port) {
        var buffer = [UInt8](repeating: 0, count: 65_550)
        while true {
            let n = recv(port.fd, &buffer, buffer.count, MSG_DONTWAIT)
            if n <= 0 { return }
            guard n >= 14 else { continue }
            let frame = Data(buffer[0..<n])
            learn(source: mac(frame, at: 6), from: port.podID)
            deliver(frame, destination: mac(frame, at: 0), cameFromPeer: nil)
        }
    }

    /// Sends a frame where it belongs: to one local pod, to one machine, or --
    /// when the address has not been seen yet, or is broadcast or multicast --
    /// to everywhere except where it came from.
    private func deliver(_ frame: Data, destination: UInt64, cameFromPeer peer: String?) {
        let isFlood = destination == 0xffff_ffff_ffff || (frame[0] & 0x01) == 1

        lock.lock()
        let localTarget = isFlood ? nil : macToPod[destination]
        let peerTarget = isFlood ? nil : macToPeer[destination]
        let allPorts = Array(ports.values)
        let allPeers = peers
        lock.unlock()

        if let podID = localTarget, let port = allPorts.first(where: { $0.podID == podID }) {
            write(frame, to: port.fd)
            lock.lock(); framesLocal += 1; lock.unlock()
            return
        }
        if let target = peerTarget, peer == nil {
            relayFrame(frame, to: target)
            lock.lock(); framesRelayed += 1; lock.unlock()
            return
        }

        // Flood. A frame that arrived from another machine is never sent back
        // out to the machines, or two switches would trade it forever.
        let origin = peer == nil ? sourcePod(of: frame) : nil
        for port in allPorts where port.podID != origin {
            write(frame, to: port.fd)
        }
        if peer == nil {
            for target in allPeers { relayFrame(frame, to: target) }
        }
    }

    private func sourcePod(of frame: Data) -> String? {
        lock.lock(); defer { lock.unlock() }
        return macToPod[mac(frame, at: 6)]
    }

    private func learn(source: UInt64, from podID: String) {
        guard source != 0, (source & 0x0100_0000_0000) == 0 else { return }
        lock.lock()
        if macToPod[source] != podID { macToPod[source] = podID }
        macToPeer.removeValue(forKey: source)
        lock.unlock()
    }

    private func learn(source: UInt64, fromPeer peer: String) {
        guard source != 0 else { return }
        lock.lock()
        if macToPeer[source] != peer { macToPeer[source] = peer }
        lock.unlock()
    }

    private func write(_ frame: Data, to fd: Int32) {
        _ = frame.withUnsafeBytes { raw in
            Darwin.send(fd, raw.baseAddress, raw.count, MSG_DONTWAIT)
        }
    }

    // MARK: - Other machines

    private func startRelay() {
        relay = socket(AF_INET, SOCK_DGRAM, 0)
        guard relay >= 0 else { return }
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
            FileHandle.standardError.write("switch: could not bind the relay port\n".data(using: .utf8)!)
            close(relay); relay = -1; return
        }
        Thread.detachNewThread { [weak self] in self?.relayLoop() }
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
            let sender = "\(String(cString: inet_ntoa(from.sin_addr))):\(UInt16(bigEndian: from.sin_port))"
            let frame = Data(buffer[0..<n])
            learn(source: mac(frame, at: 6), fromPeer: sender)
            deliver(frame, destination: mac(frame, at: 0), cameFromPeer: sender)
        }
    }

    private func relayFrame(_ frame: Data, to target: String) {
        guard relay >= 0 else { return }
        let parts = target.split(separator: ":")
        guard let host = parts.first, let port = parts.last.flatMap({ UInt16($0) }) else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, String(host), &addr.sin_addr)
        _ = frame.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(relay, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func addPeer(_ target: String) {
        lock.lock(); peers.insert(target); lock.unlock()
    }

    func peerList() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(peers).sorted()
    }

    // MARK: -

    private func mac(_ frame: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<6 { value = (value << 8) | UInt64(frame[frame.startIndex + offset + i]) }
        return value
    }
}
