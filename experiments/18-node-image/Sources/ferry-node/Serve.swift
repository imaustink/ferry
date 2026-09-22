// One process, one network, every machine on it.
//
// `ferry-node run` starts a single machine and each invocation creates a vmnet
// network of its own. That is fine for one node and wrong for a cluster:
// experiment 19 measured two processes asking for the same subnet and the
// second was refused outright -- a vmnet network belongs to the process that
// made it. With a process per machine every node lands on a different network,
// vmnet keeps those apart, and pods on two nodes cannot reach each other.
//
// So machines are hosted here instead, the way ferry-cri hosts pod VMs: one
// network, created once, and an interface on it per machine.
//
// The control channel is a directory rather than a socket. ferry-machined
// writes <name>.json to ask for a machine and removes it to stop one; this
// writes <name>.status.json back. A protocol would be more elegant and this is
// inspectable with ls, which during milestone 3 is worth more.

import Containerization
import ContainerizationExtras
import Foundation
import Virtualization

/// What ferry-machined asks for.
struct MachineSpec: Codable {
    let name: String
    let disk: String
    let cpus: Int
    let memoryMiB: UInt64
    let token: String
    /// The slice of the cluster's pod network this machine owns. Each machine
    /// gets its own, so routes between them are unambiguous.
    let podCIDR: String
    /// Taints the kubelet registers with, in its own --register-with-taints
    /// spelling. Optional, because a machine written by hand has none and an
    /// older ferry-machined does not send the field at all.
    let taints: [String]?
}

/// What this reports back about a machine it is running.
struct MachineStatus: Codable {
    let name: String
    let address: String
    let gateway: String
    let podCIDR: String
    let phase: String
    let message: String?
}

@available(macOS 26.0, *)
func serve() throws {
    let dir = option("--dir")
    let kernelPath = option("--kernel")
    let caPath = option("--ca")
    let apiServer = option("--api-server")
    let clusterDNS = option("--cluster-dns", "10.96.0.10")
    let requestedSubnet = option("--subnet", "")
    let poll = Double(option("--poll", "0.5")) ?? 0.5
    // Ferry's pod network, joined as one more switch rather than as a node.
    // Absent means machines keep to their own vmnet network and mode 1 stays
    // out of reach -- which is what every version before this did, and is still
    // what happens when mode 1 is not running.
    let switchPort = UInt16(option("--switch-port", "0")) ?? 0
    let switchPeer = option("--switch-peer", "")
    let clusterCIDR = option("--cluster-cidr", "")
    // This Mac's PersistentVolume directory, shared into every machine.
    let volumesDir = option("--volumes", "")

    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // The one network every machine joins. Created once, here, which is the
    // whole point of this mode.
    let network = try MachineNetwork(
        subnet: requestedSubnet.isEmpty ? nil : try CIDRv4(requestedSubnet))
    let podNetwork = MachineSwitch(relayPort: switchPort, peer: switchPeer)

    print("==> ferry-node serve")
    print("    dir      \(dir)")
    print("    network  \(network.subnet), gateway \(network.ipv4Gateway)")
    if podNetwork != nil {
        print("    switch   udp/\(switchPort), ferry-cri at \(switchPeer)")
    } else {
        print("    switch   off; machines cannot reach mode 1 pods")
    }

    // Held so the machines stay alive: a VZVirtualMachine that goes out of
    // scope takes its guest with it.
    let live = Live()

    // Every name this process has tried to boot, running or not.
    //
    // `live` is not that set: a machine whose boot threw never enters it, and
    // cleaning up from `live` alone leaves the failed one's vmnet address
    // assigned for as long as the process lives. Which used to be a slow leak
    // and now is not: the provisioner makes a machine per pending pod under a
    // fresh name and takes it away again a minute after it empties.
    var known: Set<String> = []

    // Stop the machines and give the subnet back, rather than being killed with
    // both still held.
    //
    // A machine whose host process is killed loses whatever it had not flushed,
    // and a node VM runs containerd over a real filesystem; and the network
    // stays reserved, so the next `ferry machines enable` waits for a subnet
    // this process abandoned. Asking again is the one thing that makes that
    // worse (experiment 22).
    let signals = onShutdownSignal {
        announce("\n==> stopping machines and releasing the machine network")
        for (name, machine) in live.take() {
            podNetwork?.detach(name: name)
            machine.stop()
            try? FileManager.default.removeItem(atPath: statusFile(name: name, in: dir))
        }
        network.release()
        announce("==> stopped")
        exit(0)
    }
    _ = signals

    while true {
        let wanted = readSpecs(in: dir)

        let running = live.all()
        for (name, spec) in wanted where running[name] == nil {
            known.insert(name)
            do {
                let machine = try boot(spec: spec, network: network, kernelPath: kernelPath,
                                       caPath: caPath, apiServer: apiServer, clusterDNS: clusterDNS,
                                       clusterCIDR: clusterCIDR, podNetwork: podNetwork,
                                       volumesDir: volumesDir)
                live.add(name, machine)
                write(status: MachineStatus(
                    name: name, address: machine.address, gateway: machine.gateway,
                    podCIDR: spec.podCIDR, phase: "Running", message: nil), in: dir)
                print("==> \(name) at \(machine.address)")
            } catch {
                print("==> \(name) failed: \(error)")
                write(status: MachineStatus(
                    name: name, address: "", gateway: "", podCIDR: spec.podCIDR,
                    phase: "Failed", message: "\(error)"), in: dir)
            }
        }

        // Experiment 26: make each machine's USB disks match its .usb file.
        if usbHotplugEnabled {
            for (name, machine) in live.all() {
                machine.reconcileUSB(wanted: usbDisks(name: name, in: dir))
            }
        }

        // Over `known` rather than over `running`, so a machine that failed to
        // boot gives its address back too.
        for name in known where wanted[name] == nil {
            if let machine = running[name] {
                print("==> \(name) stopping")
                podNetwork?.detach(name: name)
                machine.stop()
                live.remove(name)
            }
            // After stop(), which waits for the guest: an address handed out
            // again while the VM holding it is still shutting down is two
            // machines on one address for as long as that takes.
            network.releaseInterface(name)
            known.remove(name)
            try? FileManager.default.removeItem(atPath: statusFile(name: name, in: dir))
        }

        Thread.sleep(forTimeInterval: poll)
    }
}

/// The disk images `<dir>/<name>.usb` asks to have attached, one path a line.
func usbDisks(name: String, in dir: String) -> [String] {
    let path = (dir as NSString).appendingPathComponent("\(name).usb")
    guard let body = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return body.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// A machine this process is hosting.
@available(macOS 26.0, *)
final class RunningMachine {
    let vm: VZVirtualMachine
    let queue: DispatchQueue
    let console: Console
    let address: String
    let gateway: String
    /// Experiment 26: USB disks attached to the running VM, by image path.
    /// Touched only on `queue`, which is the VM's.
    private var usb: [String: VZUSBMassStorageDevice] = [:]
    private var usbPending: Set<String> = []

    /// Attaches what is wanted and not attached, detaches what is attached and
    /// no longer wanted. Asynchronous: each call is reported in the log with
    /// how long the framework took, which is half of what the experiment is
    /// measuring.
    func reconcileUSB(wanted: [String]) {
        queue.async { [self] in
            guard let controller = vm.usbControllers.first else {
                if !wanted.isEmpty { print("    usb: \(address) has no USB controller") }
                return
            }
            for path in wanted where usb[path] == nil && !usbPending.contains(path) {
                do {
                    let attachment = try VZDiskImageStorageDeviceAttachment(
                        url: URL(filePath: path), readOnly: false,
                        cachingMode: .automatic, synchronizationMode: .fsync)
                    let device = VZUSBMassStorageDevice(
                        configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
                    usbPending.insert(path)
                    let started = Date()
                    controller.attach(device: device) { error in
                        self.usbPending.remove(path)
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        if let error {
                            print("    usb: attach \(path) failed after \(ms)ms: \(error.localizedDescription)")
                        } else {
                            self.usb[path] = device
                            print("    usb: attached \(path) in \(ms)ms as \(device.uuid)")
                        }
                    }
                } catch {
                    print("    usb: cannot open \(path): \(error.localizedDescription)")
                }
            }
            for (path, device) in usb where !wanted.contains(path) {
                usb.removeValue(forKey: path)
                let started = Date()
                controller.detach(device: device) { error in
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    if let error {
                        print("    usb: detach \(path) failed after \(ms)ms: \(error.localizedDescription)")
                    } else {
                        print("    usb: detached \(path) in \(ms)ms")
                    }
                }
            }
        }
    }

    init(vm: VZVirtualMachine, queue: DispatchQueue, console: Console, address: String, gateway: String) {
        self.vm = vm
        self.queue = queue
        self.console = console
        self.address = address
        self.gateway = gateway
    }

    func stop() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [vm] in
            if vm.canRequestStop { try? vm.requestStop() }
            vm.stop { _ in done.signal() }
        }
        _ = done.wait(timeout: .now() + 10)
    }
}

@available(macOS 26.0, *)
func boot(spec: MachineSpec, network: MachineNetwork, kernelPath: String,
          caPath: String, apiServer: String, clusterDNS: String,
          clusterCIDR: String = "", podNetwork: MachineSwitch? = nil,
          volumesDir: String = "") throws -> RunningMachine {
    // An interface on the shared network, so every machine is on one segment
    // and a route between two of them is an ordinary route.
    guard let interface = try network.createInterface(spec.name) else {
        throw Failure.message("vmnet gave no interface for \(spec.name)")
    }
    let address = "\(interface.ipv4Address)"
    let gateway = interface.ipv4Gateway.map { "\($0)" } ?? ""

    let configDisk = spec.disk + ".config.ext4"
    try makeConfigDisk(caPath: caPath, out: configDisk)

    // eth1, if mode 1 is around to talk to. Made before the machine so the
    // switch has the port the moment the guest starts sending: a machine whose
    // first ARP is dropped waits out a retransmit for no reason.
    //
    // Made before the machine also means made before anything that can throw,
    // and everything below here can: machineConfiguration ends in
    // VZVirtualMachineConfiguration.validate, which rejects a cpu count or a
    // memory size the host will not take, and the start can time out. The port
    // is registered with a live read source over both ends of a socketpair, so
    // leaving on a throw leaks two descriptors and a source -- and the serve
    // loop retries the same spec every poll, attaching again over the entry it
    // left behind, twice a second, until the process runs out of descriptors.
    let podNIC: MachineNIC? = podNetwork == nil ? nil : try MachineNIC()
    if let podNIC, let podNetwork {
        podNetwork.attach(name: spec.name, fd: podNIC.hostFD)
    }
    var booted = false
    defer {
        if !booted {
            // detach cancels the source and closes ferry's end; the guest's end
            // was never handed to a running VM, so it is ours to close.
            podNetwork?.detach(name: spec.name)
            podNIC?.closeGuestSide()
        }
    }

    let console = Console()
    let config = try machineConfiguration(
        nodeName: spec.name, disk: spec.disk, configDisk: configDisk, kernelPath: kernelPath,
        cpus: spec.cpus, memoryMiB: spec.memoryMiB, apiServer: apiServer, token: spec.token,
        address: address, gateway: gateway, podCIDR: spec.podCIDR, clusterDNS: clusterDNS,
        clusterCIDR: clusterCIDR, taints: spec.taints ?? [],
        interface: interface, console: console, podNIC: podNIC,
        volumesDir: volumesDir)

    let queue = DispatchQueue(label: "ferry.node.\(spec.name)")
    let vm = VZVirtualMachine(configuration: config, queue: queue)
    let started = DispatchSemaphore(value: 0)
    let failure = Box<Error?>(nil)
    queue.async {
        vm.start { result in
            if case .failure(let error) = result { failure.value = error }
            started.signal()
        }
    }
    guard started.wait(timeout: .now() + 60) == .success, failure.value == nil else {
        throw Failure.message("starting \(spec.name): \(failure.value?.localizedDescription ?? "timed out")")
    }

    if ProcessInfo.processInfo.environment["FERRY_NODE_VERBOSE"] != nil {
        console.onLine = { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { print("    [\(spec.name)] \(text)") }
        }
    } else {
        console.onLine = { line in
            if line.contains("ferry-node:") {
                print("    [\(spec.name)] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    booted = true
    return RunningMachine(vm: vm, queue: queue, console: console, address: address, gateway: gateway)
}

enum Failure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): m }
    }
}

// MARK: - the directory as a control channel

func specFiles(in dir: String) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return names.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".status.json") }
}

func readSpecs(in dir: String) -> [String: MachineSpec] {
    var specs: [String: MachineSpec] = [:]
    for file in specFiles(in: dir) {
        let path = (dir as NSString).appendingPathComponent(file)
        guard let body = FileManager.default.contents(atPath: path),
              let spec = try? JSONDecoder().decode(MachineSpec.self, from: body)
        else { continue }
        specs[spec.name] = spec
    }
    return specs
}

func statusFile(name: String, in dir: String) -> String {
    (dir as NSString).appendingPathComponent("\(name).status.json")
}

func write(status: MachineStatus, in dir: String) {
    guard let body = try? JSONEncoder().encode(status) else { return }
    try? body.write(to: URL(filePath: statusFile(name: status.name, in: dir)))
}
