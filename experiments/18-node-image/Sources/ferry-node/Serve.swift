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
    // ferry's own segment, which carries cluster traffic because vmnet will not:
    // it forwards the addresses it assigned and drops pod addresses outright.
    let clusterSubnet = option("--cluster-subnet", "10.89.0.0/16")
    // Off by default, because it turned out not to be needed. One vmnet network
    // does carry pod-addressed traffic between machines on it -- measured, after
    // an earlier measurement against a pod that had already exited said
    // otherwise. --switch keeps the alternative available for the case mode 1
    // actually hit, which is traffic between two Macs.
    let useSwitch = CommandLine.arguments.contains("--switch")
    let poll = Double(option("--poll", "0.5")) ?? 0.5

    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // The one network every machine joins. Created once, here, which is the
    // whole point of this mode.
    let network = Box(try VmnetNetwork(
        subnet: requestedSubnet.isEmpty ? nil : try CIDRv4(requestedSubnet)))
    print("==> ferry-node serve")
    print("    dir      \(dir)")
    print("    network  \(network.value.subnet), gateway \(network.value.ipv4Gateway)")

    let machineSwitch = MachineSwitch()
    print("    cluster  \(clusterSubnet) on ferry's own switch")

    // Held so the machines stay alive: a VZVirtualMachine that goes out of
    // scope takes its guest with it.
    var running: [String: RunningMachine] = [:]
    // Addresses on the switched segment, handed out in order and remembered, so
    // a machine that is rebuilt keeps the address its neighbours route to.
    var clusterAddresses: [String: String] = [:]
    var nextClusterHost = 2

    while true {
        let wanted = readSpecs(in: dir)

        for (name, spec) in wanted where running[name] == nil {
            do {
                let clusterAddress: String
                if let known = clusterAddresses[name] {
                    clusterAddress = known
                } else {
                    let prefix = clusterSubnet.split(separator: "/").last.map(String.init) ?? "16"
                    let base = clusterSubnet.split(separator: "/").first.map(String.init) ?? "10.89.0.0"
                    let octets = base.split(separator: ".").map(String.init)
                    clusterAddress = "\(octets[0]).\(octets[1]).\(nextClusterHost / 254).\(nextClusterHost % 254 + 1)/\(prefix)"
                    clusterAddresses[name] = clusterAddress
                    nextClusterHost += 1
                }
                let machine = try boot(spec: spec, network: network, kernelPath: kernelPath,
                                       caPath: caPath, apiServer: apiServer, clusterDNS: clusterDNS,
                                       clusterAddress: useSwitch ? clusterAddress : "",
                                       machineSwitch: useSwitch ? machineSwitch : nil)
                running[name] = machine
                write(status: MachineStatus(
                    name: name, address: machine.address, gateway: machine.gateway,
                    podCIDR: spec.podCIDR, phase: "Running", message: nil), in: dir)
                print("==> \(name) at \(machine.address), cluster \(clusterAddresses[name] ?? "?")")
            } catch {
                print("==> \(name) failed: \(error)")
                write(status: MachineStatus(
                    name: name, address: "", gateway: "", podCIDR: spec.podCIDR,
                    phase: "Failed", message: "\(error)"), in: dir)
            }
        }

        for (name, machine) in running where wanted[name] == nil {
            print("==> \(name) stopping")
            machineSwitch.detach(machine: name)
            machine.stop()
            running.removeValue(forKey: name)
            try? FileManager.default.removeItem(atPath: statusFile(name: name, in: dir))
        }

        Thread.sleep(forTimeInterval: poll)
    }
}

/// A machine this process is hosting.
@available(macOS 26.0, *)
final class RunningMachine {
    let vm: VZVirtualMachine
    let queue: DispatchQueue
    let console: Console
    let address: String
    let gateway: String

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
func boot(spec: MachineSpec, network: Box<VmnetNetwork>, kernelPath: String,
          caPath: String, apiServer: String, clusterDNS: String,
          clusterAddress: String, machineSwitch: MachineSwitch?) throws -> RunningMachine {
    // An interface on the shared network, so every machine is on one segment
    // and a route between two of them is an ordinary route.
    guard let interface = try network.value.createInterface(spec.name) as? VmnetNetwork.Interface else {
        throw Failure.message("vmnet gave no interface for \(spec.name)")
    }
    let address = "\(interface.ipv4Address)"
    let gateway = interface.ipv4Gateway.map { "\($0)" } ?? ""

    let configDisk = spec.disk + ".config.ext4"
    try makeConfigDisk(caPath: caPath, out: configDisk)

    // eth1: ferry's segment, where cluster traffic lives -- unless this is the
    // vmnet-only comparison, in which case there is no second interface.
    var switchInterface: SwitchInterface? = nil
    if !clusterAddress.isEmpty {
        guard let cidr = try? CIDRv4(clusterAddress) else {
            throw Failure.message("bad cluster address \(clusterAddress)")
        }
        switchInterface = try SwitchInterface(address: cidr, mac: nil)
    }

    let console = Console()
    let config = try machineConfiguration(
        nodeName: spec.name, disk: spec.disk, configDisk: configDisk, kernelPath: kernelPath,
        cpus: spec.cpus, memoryMiB: spec.memoryMiB, apiServer: apiServer, token: spec.token,
        address: address, gateway: gateway, podCIDR: spec.podCIDR, clusterDNS: clusterDNS,
        interface: interface, console: console,
        clusterAddress: clusterAddress, switchInterface: switchInterface)
    if let switchInterface, let machineSwitch {
        machineSwitch.attach(machine: spec.name, fd: switchInterface.hostFD)
    }

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
