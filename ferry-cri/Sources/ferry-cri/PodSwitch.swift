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
        /// The host-side Service router, for a macOS pod that has no in-guest
        /// kube-proxy: it DNATs the pod's ClusterIP traffic and un-DNATs the
        /// replies. Nil for a Linux pod, which does its own in-guest DNAT.
        let nat: MacServiceNAT?
    }

    private let lock = NSLock()
    private var ports: [String: Port] = [:]          // podID -> port
    private var macToPod: [UInt64: String] = [:]     // learned, local
    private var macToPeer: [UInt64: String] = [:]    // learned, remote
    private var peers: Set<String> = []              // host:port of other machines
    /// Peers given at startup rather than discovered.
    ///
    /// These are configuration, not state, so the peers file cannot take them
    /// away -- and it used to. `--peers` was replaced wholesale on the first
    /// read of that file, which for a long time meant nothing because the file
    /// was the only source. It stopped being harmless when the machine switch
    /// arrived as a fixed peer on loopback: its entry vanished about two
    /// seconds after startup, and the failure was one-directional and therefore
    /// baffling. Frames from a machine still arrived, because that direction
    /// only needs the address the datagram came from; frames to a machine need
    /// this set, so anything not yet learned -- every ARP, which is how the
    /// conversation starts -- was flooded to nobody.
    private let configured: Set<String>
    private let queue = DispatchQueue(label: "ferry.switch", attributes: .concurrent)

    /// The UDP socket carrying frames to and from other machines.
    private var relay: Int32 = -1
    private let relayPort: UInt16

    /// Frames seen, for `ferry status`.
    private(set) var framesLocal = 0
    private(set) var framesRelayed = 0

    init(relayPort: UInt16, peers: [String], peersFile: String? = nil, self endpoint: String? = nil) {
        self.relayPort = relayPort
        self.configured = Set(peers)
        self.peers = Set(peers)
        self.ownEndpoint = endpoint
        if relayPort > 0 { startRelay() }
        if let peersFile { watchPeers(file: peersFile) }
    }

    private let ownEndpoint: String?

    /// Nodes come and go while ferry is running -- a second node on this Mac, or
    /// a whole other machine joining -- so the peer list is read from a file
    /// somebody else keeps current rather than fixed at startup.
    /// Nodes come and go while ferry is running -- a second node on this Mac, or
    /// a whole other machine joining -- so the peer list is read from a file
    /// somebody else keeps current rather than fixed at startup.
    ///
    /// The switch lives as long as the process, so this holds it strongly. A
    /// weak capture here would let one nil reading end the thread for good, and
    /// the node would silently never learn about its peers again.
    private func watchPeers(file: String) {
        Thread.detachNewThread {
            var lastSeen = ""
            while true {
                if let text = try? String(contentsOfFile: file, encoding: .utf8), text != lastSeen {
                    lastSeen = text
                    let listed = text.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && $0 != self.ownEndpoint }
                    let live = Set(listed).union(self.configured)
                    self.lock.lock()
                    self.peers = live
                    self.macToPeer = self.macToPeer.filter { live.contains($0.value) }
                    self.lock.unlock()
                    let shown = live.sorted()
                    print("    switch: peers \(shown.isEmpty ? "none" : shown.joined(separator: ", "))")
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    // MARK: - Ports

    func attach(podID: String, fd: Int32, nat: MacServiceNAT? = nil) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let port = Port(podID: podID, fd: fd, source: source, nat: nat)
        source.setEventHandler { [weak self] in self?.readFrames(from: port) }
        // The port owns the host end from here on, and closes it only once the
        // source has stopped reading it. Nothing closed it before: every pod
        // that ever ran left its socket pair open, two descriptors a pod, until
        // a busy node ran out of them.
        source.setCancelHandler { close(fd) }
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
            learnIP(frame)
            // A macOS pod's Service traffic (to the virtual gateway) is DNATed
            // here; its ARP for the gateway is answered here; everything else --
            // pod-to-pod -- falls through to normal L2 switching.
            if let nat = port.nat {
                switch nat.egress(frame) {
                case .reply(let r): write(r, to: port.fd); continue
                case .drop: continue
                case .forward(var rewritten):
                    learn(source: mac(frame, at: 6), from: port.podID)
                    // Unicast to the backend if its MAC is known (a broadcast TCP
                    // segment is dropped by a Linux endpoint). If not, ARP for it
                    // as the gateway so the retransmit can unicast, and let this
                    // one flood as a best effort.
                    if let dip = dstIPv4(rewritten) {
                        if let m = macForIP(dip) { setDstMAC(&rewritten, m) }
                        else if let nat = port.nat { arpFor(dip, senderIP: nat.gwIP, senderMAC: nat.gwMAC) }
                    }
                    deliver(rewritten, destination: mac(rewritten, at: 0), cameFromPeer: nil)
                    continue
                case .pass: break
                }
            }
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
            send(frame, to: port)
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
            send(frame, to: port)
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

    /// Deliver to a port, un-DNATing a macOS pod's Service replies on the way in
    /// (an endpoint's source rewritten back to the ClusterIP the pod dialed).
    private func send(_ frame: Data, to port: Port) {
        write(port.nat.map { $0.ingress(frame) } ?? frame, to: port.fd)
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
            learnIP(frame)
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

    // MARK: - IPv4 -> MAC, for the Service DNAT

    /// Learned IPv4 -> MAC, so a DNATed Service frame can be unicast to the
    /// backend pod rather than flooded. Filled by snooping every frame's source
    /// (and ARP senders) as they cross the switch.
    private var ipToMAC: [UInt32: UInt64] = [:]

    private func u32be(_ d: Data, _ o: Int) -> UInt32 {
        var v: UInt32 = 0; for i in 0..<4 { v = (v << 8) | UInt32(d[d.startIndex + o + i]) }; return v
    }

    private func learnIP(_ frame: Data) {
        guard frame.count >= 14 else { return }
        let et = (UInt16(frame[frame.startIndex + 12]) << 8) | UInt16(frame[frame.startIndex + 13])
        let ip: UInt32, m: UInt64
        if et == 0x0800, frame.count >= 34 { ip = u32be(frame, 26); m = mac(frame, at: 6) }        // IPv4 src
        else if et == 0x0806, frame.count >= 42 { ip = u32be(frame, 28); m = mac(frame, at: 22) }   // ARP sender
        else { return }
        guard ip != 0, m != 0, (m & 0x0100_0000_0000) == 0 else { return }
        lock.lock(); if ipToMAC[ip] != m { ipToMAC[ip] = m }; lock.unlock()
    }

    private func macForIP(_ ip: UInt32) -> UInt64? { lock.lock(); defer { lock.unlock() }; return ipToMAC[ip] }

    /// The IPv4 destination of a frame, when it is IPv4.
    private func dstIPv4(_ frame: Data) -> UInt32? {
        guard frame.count >= 34,
              (UInt16(frame[frame.startIndex + 12]) << 8 | UInt16(frame[frame.startIndex + 13])) == 0x0800
        else { return nil }
        return u32be(frame, 30)
    }

    private func setDstMAC(_ frame: inout Data, _ m: UInt64) {
        for i in 0..<6 { frame[frame.startIndex + i] = UInt8((m >> (8 * (5 - i))) & 0xff) }
    }

    /// Broadcast an ARP request for a backend, sent as the Service gateway, so its
    /// reply is snooped into `ipToMAC` and the next DNATed frame can be unicast.
    private func arpFor(_ targetIP: UInt32, senderIP: UInt32, senderMAC: [UInt8]) {
        var f = Data(count: 42)
        for i in 0..<6 { f[i] = 0xff; f[6 + i] = senderMAC[i] }          // dst broadcast, src gateway
        f[12] = 0x08; f[13] = 0x06
        f[14] = 0; f[15] = 1; f[16] = 0x08; f[17] = 0; f[18] = 6; f[19] = 4; f[20] = 0; f[21] = 1  // request
        for i in 0..<6 { f[22 + i] = senderMAC[i] }                       // sender = gateway
        for i in 0..<4 { f[28 + i] = UInt8((senderIP >> (8 * (3 - i))) & 0xff) }
        for i in 0..<4 { f[38 + i] = UInt8((targetIP >> (8 * (3 - i))) & 0xff) }
        deliver(f, destination: 0xffff_ffff_ffff, cameFromPeer: nil)
    }
}
