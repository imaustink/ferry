// A macOS machine: the same place on ferry's networks as a Linux one, a
// different guest.
//
// A Linux machine is a kernel and an ext4 root, told who it is on the kernel
// command line. A macOS machine is a VM bundle cloned from a golden image
// (experiment 39) -- Disk.img, AuxiliaryStorage and the hardware and machine
// identifiers -- booted by VZMacOSBootLoader, which takes no command line. So
// what the command line carries goes in a directory shared read-only into the
// guest as "ferry-config", one value a file, and the golden image's boot
// daemon (ferry-macos-init) reads it.
//
// Its network is a Linux machine's, card for card: en0 on the machine network
// with the address vmnet gave, and en1 on ferry's pod switch. What differs is
// inside -- the guest's pods are processes, their addresses aliases on en1,
// and the runtime is ferry-darwin.
//
// There is no console: a macOS guest writes nothing to a virtio console. The
// guest agent's vsock port is attached, so a machine can be looked into.

import Containerization
import ContainerizationExtras
import Foundation
import Virtualization

let macConfigTag = "ferry-config"
let macLogsTag = "ferry-logs"

@available(macOS 26.0, *)
func bootMac(spec: MachineSpec, network: MachineNetwork, caPath: String, apiServer: String,
             clusterDNS: String, clusterCIDR: String, podNetwork: MachineSwitch?,
             volumesDir: String) throws -> RunningMachine {
    let bundle = URL(filePath: spec.disk)
    guard let hw = VZMacHardwareModel(dataRepresentation:
            try Data(contentsOf: bundle.appending(path: "HardwareModel.bin"))),
          let id = VZMacMachineIdentifier(dataRepresentation:
            try Data(contentsOf: bundle.appending(path: "MachineIdentifier.bin")))
    else { throw Failure.message("\(spec.disk) is not a macOS VM bundle") }

    guard let interface = try network.createInterface(spec.name) else {
        throw Failure.message("vmnet gave no interface for \(spec.name)")
    }
    let address = "\(interface.ipv4Address)"
    let gateway = interface.ipv4Gateway.map { "\($0)" } ?? ""

    // What a Linux machine reads from its command line and its config disk.
    let configDir = spec.disk + ".config"
    try? FileManager.default.removeItem(atPath: configDir)
    try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    var values: [String: String] = [
        "node": spec.name, "api": apiServer, "token": spec.token,
        "address": address, "gateway": gateway, "dnssvc": clusterDNS,
        "clustercidr": clusterCIDR, "taints": (spec.taints ?? []).joined(separator: ","),
    ]
    if let port = ProcessInfo.processInfo.environment["FERRY_NODE_REGISTRY_PORT"], !port.isEmpty {
        values["registry"] = port
    }
    if !volumesDir.isEmpty { values["volumes"] = volumesDir }
    if let mode = spec.mode, !mode.isEmpty { values["mode"] = mode }
    if let maxPods = spec.maxPods, maxPods > 0 { values["maxpods"] = "\(maxPods)" }
    for (key, value) in values {
        try Data(value.utf8).write(to: URL(filePath: configDir).appending(path: key))
    }
    try FileManager.default.copyItem(atPath: caPath, toPath: configDir + "/ca.crt")

    let podNIC: MachineNIC? = podNetwork == nil ? nil : try MachineNIC()
    if let podNIC, let podNetwork {
        podNetwork.attach(name: spec.name, fd: podNIC.hostFD)
    }
    var booted = false
    defer {
        if !booted {
            podNetwork?.detach(name: spec.name)
            podNIC?.closeGuestSide()
        }
    }

    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = hw
    platform.machineIdentifier = id
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.appending(path: "AuxiliaryStorage"))

    let config = VZVirtualMachineConfiguration()
    config.platform = platform
    config.bootLoader = VZMacOSBootLoader()
    config.cpuCount = spec.cpus
    config.memorySize = spec.memoryMiB * 1024 * 1024
    let sync = diskSynchronizationMode(
        spec.diskSync, serverDefault: ProcessInfo.processInfo.environment["FERRY_NODE_DISK_SYNC"])
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment:
        try VZDiskImageStorageDeviceAttachment(url: bundle.appending(path: "Disk.img"), readOnly: false,
                                               cachingMode: .automatic, synchronizationMode: sync))]
    // A Linux machine configures eth0 and eth1 by name, in attach order. A
    // macOS guest's names do not follow the order -- it already has an en1 of
    // its own before either card is attached -- so each card gets a MAC
    // address the guest is told, and it finds its cards by that.
    let machineCard = try interface.device()
    let podCardMAC = VZMACAddress.randomLocallyAdministered()
    try Data(machineCard.macAddress.string.utf8).write(to: URL(filePath: configDir).appending(path: "mac"))
    config.networkDevices = [machineCard]
    if let podNIC {
        let podCard = podNIC.device()
        podCard.macAddress = podCardMAC
        try Data(podCardMAC.string.utf8).write(to: URL(filePath: configDir).appending(path: "podmac"))
        config.networkDevices.append(podCard)
    }
    let gfx = VZMacGraphicsDeviceConfiguration()
    gfx.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1024, heightInPixels: 768, pixelsPerInch: 80)]
    config.graphicsDevices = [gfx]
    config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    let cfgShare = VZVirtioFileSystemDeviceConfiguration(tag: macConfigTag)
    cfgShare.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(filePath: configDir), readOnly: true))
    // Where the guest writes its boot, runtime and kubelet logs: a macOS guest
    // has no console to read, and without this a machine that does not join is
    // a machine that says nothing about why.
    let logsDir = spec.disk + ".logs"
    try? FileManager.default.removeItem(atPath: logsDir)
    try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
    let logShare = VZVirtioFileSystemDeviceConfiguration(tag: macLogsTag)
    logShare.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(filePath: logsDir), readOnly: false))
    config.directorySharingDevices = [cfgShare, logShare]
    if !volumesDir.isEmpty && FileManager.default.fileExists(atPath: volumesDir) {
        let share = VZVirtioFileSystemDeviceConfiguration(tag: volumesTag)
        share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(filePath: volumesDir), readOnly: false))
        config.directorySharingDevices.append(share)
    }
    try config.validate()

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
        // The one failure worth naming: the Mac runs two macOS guests at most,
        // and a third is refused at start whatever else is free.
        throw Failure.message("starting macOS machine \(spec.name): \(failure.value?.localizedDescription ?? "timed out")")
    }
    print("    [\(spec.name)] macOS machine started from \(spec.disk)")
    booted = true
    return RunningMachine(vm: vm, queue: queue, console: Console(), address: address, gateway: gateway)
}
