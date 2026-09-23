// The runtime behind the CRI surface: one virtual machine per pod.
//
// A CRI sandbox becomes a LinuxPod, and a CRI container becomes a process with
// its own root filesystem inside that pod's VM. Containers in a pod therefore
// share a network stack and an IPC namespace because they share a kernel --
// there is no pause container and no namespace plumbing, the VM boundary is the
// pod boundary.

import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import NIOPosix
import Synchronization

struct RuntimeConfig: Sendable {
    var stateDir: URL
    var kernelPath: String
    var podSubnet: String
    var initImage: String
    var defaultCPUs: Int
    var defaultMemoryBytes: UInt64
    /// Host directory holding nft and its loader, mounted into every pod so it
    /// can apply the Service rules kube-proxy rendered.
    var nftBundlePath: String?
    /// ferry-proxyd's socket, where the rendered ruleset comes from.
    var proxydSocket: String?
    /// ferry-netpol's socket, where each pod's NetworkPolicy rules come from.
    var netpolSocket: String?
    /// ferry-gpud's control socket, where a pod that asked for ferry.dev/gpu
    /// gets a socket to the Mac's GPU. Absent leaves the node without one.
    var gpudSocket: String?
    /// The cluster pod network, one flat segment across every node on every
    /// machine. Empty leaves ferry on vmnet addressing and a single node.
    var clusterCIDR: String?
    /// This node's slice of it. Pods here are 10.244.<index>.x when the cluster
    /// network is 10.244.0.0/16.
    var nodeIndex: Int
    /// UDP port carrying frames to other machines. 0 keeps the switch local.
    var relayPort: UInt16
    /// host:port of the other nodes' switches, at startup.
    var peers: [String]
    /// A file listing every relay endpoint in the cluster, kept current by
    /// ferry-streamer as nodes join and leave.
    var peersFile: String?
    /// This node's own endpoint, so it can be skipped in that list.
    var relayEndpoint: String?
    /// The machines' switch on this Mac, if mode 2 is on: `ferry-node` holds
    /// the other end of ferry's pod network for the machines it runs.
    ///
    /// Deliberately not one of `peers`, though frames are flooded to it exactly
    /// as they are to one. `peers` answers a second question -- are there other
    /// nodes whose routes point at this node's slice -- and that question
    /// decides whether a node that cannot get its slice falls back or refuses.
    /// Counted as a peer, turning mode 2 on would quietly turn a single-Mac
    /// cluster from one that starts anyway into one that refuses to, for a
    /// process on loopback that is not a node and routes to nothing.
    var machineSwitch: String?
    /// ferry-cni, the CNI runtime. Absent leaves ferry allocating addresses
    /// itself, which is what it did before it had one.
    var cniBinary: String?
    /// The network configuration to run. Generated from clusterCIDR and
    /// nodeIndex when not supplied, so the default needs no file.
    var cniConflist: String?
    /// darwin/arm64 plugins, forked here.
    var cniHostPlugins: String?
    /// linux/arm64 plugins, shared into every pod and run in its own kernel.
    var cniGuestPlugins: String?
    /// This process's own exec socket. ferry-cni dials back to it to run a
    /// plugin inside a pod, because only this process owns the VMs.
    var execSocket: String?
    /// Appended to every pod VM's kernel command line, after ferry's own.
    var extraKernelArgs: [String] = []
}

enum RuntimeFailure: Error, CustomStringConvertible {
    case notFound(String)
    case invalid(String)
    case unsupported(String)
    /// Something this call needs is held by another pod, and will be free once
    /// that pod is gone. The kubelet retries, so this resolves on its own.
    case busy(String)

    var description: String {
        switch self {
        case .notFound(let m): "not found: \(m)"
        case .invalid(let m): "invalid: \(m)"
        case .unsupported(let m): "unsupported: \(m)"
        case .busy(let m): "in use: \(m)"
        }
    }
}

struct SandboxRecord {
    let id: String
    var pod: LinuxPod
    let name: String
    let uid: String
    let namespace: String
    let attempt: UInt32
    let labels: [String: String]
    let annotations: [String: String]
    let ip: String
    let logDirectory: String
    let createdAt: Int64
    var ready: Bool = true
    /// Set when the pod has asked for something its running VM cannot give it
    /// -- a container arriving after the boot -- so the only way forward is a
    /// new sandbox. Reported to the kubelet as NOTREADY, which is what makes it
    /// kill the pod and create it again with every container present from the
    /// start. Kept apart from `ready` because stopPodSandbox uses that to
    /// decide whether there is anything left to tear down, and here there is.
    var needsRecreate: Bool = false
    /// What the kubelet is told about this sandbox.
    var reportedReady: Bool { ready && !needsRecreate }
    /// Whether the VM has been booted. Virtualization.framework cannot hotplug
    /// a device, and a pod's images and volumes are devices, so the VM is
    /// booted lazily on the first StartContainer rather than at RunPodSandbox,
    /// once the pod's containers -- and with them its images -- are known.
    var booted: Bool = false
    /// Which images the running VM has attached, and its scratch disk. A
    /// container of one of these images can join the VM at any time; see
    /// PodRootfs.swift.
    var rootfsLayout = PodRootfsLayout()
    var usesReservedAddress: Bool = false
    /// Kept so the VM can be rebuilt if every container in it has stopped --
    /// see replaceBootedPod.
    let interface: any Interface
    /// eth1, kept for the same reason: a pod rebuilt before it boots -- see
    /// rebuildUnbootedPod -- has to be the same machine it was about to be.
    var clusterInterface: SwitchInterface?
    let config: Runtime_V1_PodSandboxConfig
    /// Names of the pod's regular containers, from its spec. The kubelet
    /// creates them one at a time and this hypervisor cannot add a container to
    /// a running VM, so the boot waits until they have all arrived. Empty when
    /// the pod spec could not be read, in which case the VM boots on the first
    /// start as it always did.
    var expectedContainers: [String] = []
    var initContainerNames: [String] = []
    /// The subPaths the pod spec mounts of each PersistentVolume, by volume
    /// name, so a first format can make every one of them -- including those of
    /// containers the kubelet has not shown this runtime yet.
    var volumeSubPaths: [String: [String]] = [:]
    /// Every image the pod spec names, so a VM booted for its first container
    /// -- an init container, a native sidecar -- also has the images of the
    /// containers that come after it, if they are pulled.
    var specImages: [String] = []
    /// Containers in this pod that asked for ferry.dev/gpu, from its spec.
    var gpuContainerNames: [String] = []
    /// What this pod is worth against other pods waiting for the GPU.
    var priority: Int32 = 0
    /// How the VM was sized, so a rebuild after a failed start makes the same
    /// machine rather than falling back to the default.
    var vmMemoryBytes: UInt64 = 0
    var vmCPUs: Int = 0
    /// Whether ferry-gpud has bound a socket for this pod, so it can be handed
    /// back when the pod goes away.
    var gpuGranted: Bool = false
    /// Containers the kubelet has started that are waiting for the VM.
    var pendingStart: [String] = []
    /// Whether the guest half of the CNI chain has run. The kubelet starts each
    /// container in turn and the chain is per pod, not per container.
    var cniChainDone: Bool = false
    /// Block-backed PersistentVolumes this pod holds, attached to its VM as
    /// pod-level volumes. A LinuxPod's volumes are fixed when it is made, and
    /// the kubelet only says which volumes a container wants when it creates
    /// that container, so a new one here means a new LinuxPod.
    var blockVolumes: [BlockVolume] = []
    /// The ones the current LinuxPod was made with. Differing from
    /// blockVolumes is what says it has to be made again.
    var podVolumes: [BlockVolume] = []
    /// subPaths inside those volumes, as guest paths, to create once the VM
    /// is up. A bind mount needs its source to exist, and on Linux the kubelet
    /// would have made the directory -- here it made one on the Mac beside the
    /// image, which the filesystem inside it knows nothing about.
    var blockSubPaths: [String] = []
    /// emptyDirs with `medium: Memory`, by volume name, and the size of the
    /// tmpfs each one is -- see memoryVolumeSizes.
    var memoryVolumes: [String: UInt64] = [:]
    /// Their contents, archived out of a VM that is being replaced, to be put
    /// back into the next one once it boots. Empty the rest of the time.
    var carriedVolumes: [String: Data] = [:]
}

struct ContainerRecord {
    let id: String
    let sandboxID: String
    let name: String
    let attempt: UInt32
    let image: String
    let imageRef: String
    let labels: [String: String]
    let annotations: [String: String]
    /// Where the kubelet reads the log. For a removed container, the link
    /// retainedLog made to it instead.
    var logPath: String
    let createdAt: Int64
    var startedAt: Int64 = 0
    var finishedAt: Int64 = 0
    var exitCode: Int32 = 0
    var state: ContainerRunState = .created
    var reason: String = ""
    var tty: Bool = false
    var logWriters: [ContainerLogWriter] = []
    var logFile: ContainerLogFile?
    /// Present only when the pod spec set stdin. A container that did not ask
    /// for stdin must see it closed, or anything reading from it hangs instead
    /// of getting EOF.
    var stdinFeeder: FrameReaderStream?
    /// What it is added to its LinuxPod with. A container created before the
    /// VM boots is added once the VM is up -- see bootPod.
    var registration: ContainerRegistration?
    /// The kubelet's mounts, as it sent them, for ContainerStatus.
    var mounts: [Runtime_V1_Mount] = []
}

struct ContainerRegistration: Sendable {
    /// The image's own ext4, never written: the container's root is an overlay
    /// of it. See PodRootfs.swift.
    let rootfs: Containerization.Mount
    let configure: @Sendable (inout LinuxPod.ContainerConfiguration) throws -> Void
}

enum ContainerRunState {
    case created, running, exited
}

actor PodRuntime {
    private let config: RuntimeConfig
    private let store: ImageStore
    private let kernel: Kernel
    private var initfs: Containerization.Mount!
    private var network: PodNetwork!

    /// An address held back for cluster DNS. CoreDNS has to live at an address
    /// the kubelet can be configured with before CoreDNS exists, so one is
    /// reserved at startup and handed to whichever sandbox asks for it by
    /// annotation. Without this the kubelet's clusterDNS would have to be
    /// guessed, or changed after the fact and the kubelet restarted.
    private var dnsInterface: (any Interface)?
    private var dnsInterfaceInUse = false

    /// Annotation a pod sets to claim the reserved DNS address.
    static let reservedAddressAnnotation = "ferry.sh/reserved-address"

    private var sandboxes: [String: SandboxRecord] = [:]
    private var containers: [String: ContainerRecord] = [:]

    /// Unpacked, read-only root filesystems keyed by image reference. A pod
    /// attaches each one it runs read-only, and its containers overlay their
    /// writes on it; nothing ever writes to one of these.
    private var rootfsCache: [String: Containerization.Mount] = [:]
    private var pulledImages: [String: Runtime_V1_Image] = [:]
    /// The image's own entrypoint, cmd, env and working directory. The kubelet
    /// sends only the pod's overrides, so without this a container built around
    /// an ENTRYPOINT gets its arguments alone and fails to exec.
    private var imageConfigs: [String: ContainerizationOCI.ImageConfig] = [:]

    /// The event loops every pod VM's guest-agent connections run on.
    ///
    /// Left to itself, Containerization gives each VM a group of its own -- one
    /// thread per core, per pod -- and shuts that group down at the start of
    /// the VM's stop, before the VM itself is stopped. Anything still in flight
    /// on that pod's agent at that moment -- the task reaping a container's
    /// exit, an nft or CNI exec, a stats call -- then tries to schedule its
    /// completion on a loop that is gone. NIO does not fail those: it prints
    /// "Cannot schedule tasks on an EventLoop that has already shut down" and
    /// drops the work, so the caller waits forever. A 14-pod stress run logged
    /// 534 of those lines before the runtime died. (And when a VM had already
    /// died on its own, stop() refused before reaching the shutdown, which
    /// leaked a core's worth of threads per pod instead.)
    ///
    /// Handing the manager a group makes the VM a borrower: stop() no longer
    /// shuts it down, a torn-down pod's connections fail as closed channels,
    /// and one pod's teardown stays that pod's problem. It is never shut down
    /// by this process; exit reclaims it.
    private let eventLoops = MultiThreadedEventLoopGroup(
        numberOfThreads: ProcessInfo.processInfo.activeProcessorCount)

    /// Which sandbox holds each block-backed PersistentVolume, and the
    /// descriptor its lock is held on. Keyed by the volume's directory.
    ///
    /// The map is what stops two pods on this node attaching one image; the
    /// lock -- flock on the volume directory -- is what stops two processes,
    /// another ferry-cri on this Mac, from doing the same. Both live only as
    /// long as this process, which is also how long its VMs live, so a restart
    /// starts with nothing attached and nothing claimed.
    private var blockClaims: [String: (sandboxID: String, fd: Int32)] = [:]

    /// Starts at this boot's time rather than zero, so an ID is never reused
    /// by a later ferry-cri. The kubelet keeps the IDs it saw -- a pod's
    /// status names its last container through a restart of this process --
    /// and a counter from zero handed those same IDs to new containers.
    /// Seconds shifted past 24 bits of counter: a run would need 16 million
    /// IDs per second of uptime before it met the next boot's.
    private var idCounter: UInt64 = UInt64(Date().timeIntervalSince1970) << 24

    /// Containers the kubelet has removed, kept answering ContainerStatus for a
    /// minute with their log at the link retainedLog made -- see removeContainer.
    /// Never listed, so nothing the kubelet derives from ListContainers changes.
    private var removedContainers: [String: ContainerRecord] = [:]
    static let removedContainerTTL: Duration = .seconds(60)
    /// Used only to read pod specs, so the VM can wait for a pod's whole
    /// container set before booting.
    var streamer: StreamerClient?

    init(config: RuntimeConfig) throws {
        self.config = config
        try FileManager.default.createDirectory(at: config.stateDir, withIntermediateDirectories: true)
        self.store = try ImageStore(path: config.stateDir)
        var commandLine = Kernel.CommandLine(debug: false, panic: 0)
        commandLine.kernelArgs += Self.podKernelArgs + config.extraKernelArgs
        self.kernel = Kernel(path: URL(filePath: config.kernelPath), platform: .linuxArm,
                             commandline: commandLine)
        // Nothing from a previous run is running: its VMs died with it. So its
        // retained logs are orphans, which IDs that never repeat would
        // otherwise leave behind for good. Its disks go in sweepContainerDisks.
        let fm = FileManager.default
        try? fm.removeItem(at: config.stateDir.appending(component: Self.retainedLogDirectory))
        try? fm.createDirectory(at: config.stateDir.appending(component: Self.retainedLogDirectory),
                                withIntermediateDirectories: true)
    }

    /// What every pod's kernel is booted with beyond Containerization's
    /// defaults. Both are memory the guest touches at boot for nothing, and
    /// the host keeps every page a guest has touched -- the balloon does not
    /// give them back (experiments 14 and 32).
    ///
    /// No bounce buffer. Guest memory starts at 1.75 GiB, so any VM over
    /// 2304 MiB reaches past 4 GiB and the kernel sets aside 64 MiB for devices
    /// that can only address below it -- zeroed at boot, so paid for in full.
    /// A VM has no such device: its virtio devices do not negotiate
    /// ACCESS_PLATFORM, so they bypass the DMA API and the buffer is never
    /// used. 271 MiB to 206 for an idle 4 GiB pod.
    ///
    /// Transparent huge pages are off. A guest with more than 512 MiB turns
    /// them on for regions that ask, something in the guest's own boot path
    /// asks, and each one is 2 MiB of memory the host backs whole for what
    /// would otherwise have been a few 4 KiB pages: 24 MiB of every idle pod
    /// VM of 2 GiB, and nothing below 512 MiB, where the kernel leaves THP
    /// off by itself (experiments/32-pod-memory-footprint). The host backs
    /// guest memory in its own pages whatever the guest does, so a huge page
    /// in the guest buys a shorter guest page walk and nothing more.
    static let podKernelArgs = ["swiotlb=noforce", "transparent_hugepage=never"]

    /// Pulls the guest agent image and creates the pod network. Kept out of
    /// init so failures surface with context before the server starts serving.
    func setStreamer(_ client: StreamerClient) { self.streamer = client }

    func prepare() async throws {
        let initImage = try await store.getInitImage(reference: config.initImage)
        let initPath = config.stateDir.appending(component: "init.ext4")
        do {
            self.initfs = try await initImage.initBlock(at: initPath, for: .linuxArm)
        } catch let error as ContainerizationError where error.code == .exists {
            self.initfs = .block(format: "ext4", source: initPath.path(), destination: "/", options: ["ro"])
        }
        await rehydrateImages()
        sweepContainerDisks()
        // A vmnet subnet stays reserved for about a minute after the process
        // using it exits -- measured, not guessed: see experiments/07-vmnet-leak.
        // So a restart normally cannot have its previous subnet back, and waiting
        // for it would cost the user a minute of startup for nothing. Moving to
        // another is right; what it costs is a changed gateway, which is part of
        // the CoreDNS manifest and so rolls CoreDNS out again.
        // When there is a cluster network, the node's slice of it *is* the vmnet
        // subnet -- that is what puts the Mac on the pod network.
        let preferredSubnet = config.clusterCIDR
            .flatMap { Self.nodeSlice(of: $0, node: config.nodeIndex) } ?? config.podSubnet

        // Moving to another subnet is only harmless while this Mac is the whole
        // cluster. With another node in it, the fallback is not a changed gateway
        // -- it is the wrong network. The other Macs route this node's slice over
        // the switch, the node goes on advertising that slice as its podCIDR, and
        // the pods are somewhere else entirely, so nothing reaches them and every
        // node still reads Ready. TCP breaks along with everything else, which is
        // not a thing anyone would look for in a subnet allocator.
        //
        // So the cost of waiting is paid where it buys something. Alone, fall back
        // at once and say what it means. With peers, wait for the reservation to
        // lapse, and if it never does, refuse -- a node that cannot hold its own
        // slice has nothing useful to offer a cluster it cannot talk to.
        // The override exists because "refuse" is the right default and a bad
        // absolute: vmnet can stay exhausted well past the minute it documents,
        // and someone who understands this node will be cut off is better served
        // by a cluster that starts than by one that cannot.
        let allowOffSlice = ProcessInfo.processInfo.environment["FERRY_ALLOW_OFF_SLICE"] == "1"
        let peers = allowOffSlice ? [] : Self.otherPeers(config: config)
        var chosen: PodNetwork?
        var chosenSubnet = preferredSubnet
        var lastError: Error?

        if !peers.isEmpty {
            let deadline = Date().addingTimeInterval(Self.sliceWaitSeconds)
            var announced = false
            while true {
                do {
                    chosen = try PodNetwork(subnet: try CIDRv4(preferredSubnet))
                    lastError = nil
                    break
                } catch {
                    lastError = error
                }
                if Date() >= deadline { break }
                if !announced {
                    announced = true
                    let others = peers.count == 1
                        ? "1 other node routes to it"
                        : "\(peers.count) other nodes route to it"
                    print("    waiting for \(preferredSubnet); it is this node's slice and \(others)")
                }
                // Far apart on purpose, and this is the whole reason the wait
                // ever worked or did not. A refused create renews the
                // reservation it was refused by (experiment 22), so asking
                // every three seconds guaranteed the subnet stayed taken for
                // as long as ferry kept wanting it -- the wait could not
                // succeed, however long it ran. Measured: 601 asks over ten
                // minutes never got the subnet, and one ask after ninety
                // seconds of silence did.
                try? await Task.sleep(for: .seconds(Self.sliceRetrySeconds))
            }
            guard let held = chosen else {
                // Built by concatenation rather than as one multiline literal:
                // this goes straight to a terminal, and the indentation of a
                // literal nested this deep ends up in the output.
                let message = [
                    "this node's slice of the pod network, \(preferredSubnet), is not available",
                    "from vmnet after \(Int(Self.sliceWaitSeconds)) seconds, and this cluster has",
                    "other nodes that route to it: \(peers.joined(separator: ", ")).",
                    "",
                    "Starting on another subnet would put this node's pods off the pod network",
                    "while the node kept advertising \(preferredSubnet). Nothing would reach",
                    "them, and every node would still report Ready. Refusing instead.",
                    "",
                    "vmnet holds a subnet for a while after the process using it stops, and",
                    "allows 32 across the whole Mac, so this often clears on its own -- wait",
                    "and try again. If it does not, something else is holding it: look for",
                    "other VMs, and for another ferry running from a different checkout.",
                    "",
                    "To start anyway, knowing this node will not reach the others:",
                    "  FERRY_ALLOW_OFF_SLICE=1 ferry up",
                ].joined(separator: "\n")
                throw RuntimeFailure.unsupported(message)
            }
            chosen = held
        } else {
            for candidate in Self.subnetCandidates(preferred: preferredSubnet) {
                do {
                    chosen = try PodNetwork(subnet: try CIDRv4(candidate))
                    chosenSubnet = candidate
                    if candidate != preferredSubnet {
                        print("    \(preferredSubnet) is still reserved by a recent run; using \(candidate)")
                        if config.clusterCIDR != nil {
                            let others = Self.otherPeers(config: config)
                            if others.isEmpty {
                                print("    note: these pods are outside the pod network, so another "
                                    + "Mac cannot join this cluster until it starts on \(preferredSubnet)")
                            } else {
                                print("    WARNING: starting off-slice with other nodes in this "
                                    + "cluster (\(others.joined(separator: ", ")))")
                                print("    Nothing on another Mac will reach these pods, and every "
                                    + "node will still report Ready.")
                            }
                        }
                    }
                    lastError = nil
                    break
                } catch {
                    lastError = error
                }
            }
        }
        guard let chosen else {
            // vmnet allows 32 networks across the whole Mac, shared with anything
            // else using it, and each of ferry's is held for about a minute after
            // it stops. Enough restarts in quick succession exhausts the list, and
            // the raw VMNET_FAILURE says none of that.
            throw lastError ?? RuntimeFailure.unsupported(
                "no pod subnet is available. vmnet allows 32 networks across the "
                + "whole Mac and holds each for about a minute after the process "
                + "using it stops, so this usually clears on its own -- wait a "
                + "minute and try again. Otherwise check for other VMs still running.")
        }
        self.network = chosen

        // The API server has to advertise the gateway of whichever subnet was
        // actually obtained, so publish it for whoever starts the control plane.
        try? "\(chosen.ipv4Gateway)\n".write(
            to: config.stateDir.appending(component: "gateway"),
            atomically: true, encoding: .utf8)


        // The cluster pod network is carried by two interfaces that share one
        // address, and the reason is the Mac.
        //
        // A pod's address used to live only on ferry's switch, which carries
        // traffic between pods and which the host is not on -- so the Mac could
        // not reach a pod by the address the cluster knew it by. Everything the
        // Mac does to a pod needed a translation: probes, port forwarding, the
        // host side of a Service. Aggregated APIs could not work at all, because
        // the API server is a macOS process and had nowhere to send the request.
        //
        // The Mac is already on every vmnet network, for nothing. So this node's
        // vmnet network is now its own slice of the cluster CIDR -- pods get
        // 10.244.<node>.x from vmnet itself, the Mac is on that subnet natively,
        // and a pod is reachable from the host at its real address.
        //
        // The switch is still needed for the other nodes, and eth1 carries the
        // same address with a wider prefix. Longest match does the rest: the
        // local /24 leaves by eth0 on the kernel's own datapath, the rest of the
        // /16 leaves by eth1, and the source address is the same either way.
        //
        // Only on the slice, though. Off it, a pod's address is a fallback vmnet
        // one like 192.168.66.5, and giving eth1 that address with the cluster's
        // prefix routed all of 192.168.0.0/16 into the switch -- which is where
        // most Macs' LAN address lives, and so where the API server's advertised
        // endpoint went. The gateway still answered, because its /24 on eth0 is
        // the longer match, so the API server looked reachable from the host and
        // from `curl 192.168.66.1`, while the kubernetes Service, CoreDNS and
        // with it every name lookup in the cluster failed. A pod off the slice
        // is not on the cluster network in any case: nothing on the switch has
        // a route back to its address. So it gets no eth1, and reaches
        // everything -- the API server included -- through vmnet.
        let onSlice = chosenSubnet == preferredSubnet
        if let cidr = config.clusterCIDR, let slice = Self.nodeSlice(of: cidr, node: config.nodeIndex) {
            self.cni = try makeCNI()
            if onSlice {
                self.podSwitch = PodSwitch(
                    relayPort: config.relayPort,
                    peers: config.peers + (config.machineSwitch.map { [$0] } ?? []),
                    peersFile: config.peersFile,
                    self: config.relayEndpoint)
                self.clusterPrefixLength = Self.prefixLength(of: cidr) ?? 16
                print("    pod network \(cidr), this node is \(slice)")
            } else {
                self.clusterPrefixLength = Self.prefixLength(of: chosenSubnet) ?? 24
                print("    pod network \(cidr), this node is off its slice \(slice); switch off")
            }
            if cni != nil {
                print("    cni       \(config.cniConflist ?? defaultConflistPath.path())")
            }
            if onSlice, config.relayPort > 0 {
                print("    switch    udp/\(config.relayPort), peers: \(config.peers.isEmpty ? "none yet" : config.peers.joined(separator: ", "))")
            }
        }

        // Reserve and publish the cluster DNS address before any pod can take it.
        if let reserved = try? self.network.createInterface("ferry-dns") {
            self.dnsInterface = reserved
            let address = "\(reserved.ipv4Address)".split(separator: "/").first.map(String.init) ?? ""
            try? "\(address)\n".write(
                to: config.stateDir.appending(component: "dns"),
                atomically: true, encoding: .utf8)
        }
    }

    /// Where a generated configuration is written, so it can be read and edited.
    private var defaultConflistPath: URL {
        config.stateDir.appending(component: "ferry.conflist")
    }

    /// Assembles the CNI runtime, and writes a configuration for it when the
    /// operator did not supply one. Returns nil when ferry-cni is not present,
    /// which leaves the pod network unaddressed and is reported as such.
    private func makeCNI() throws -> CNIRuntime? {
        guard let binary = config.cniBinary, FileManager.default.fileExists(atPath: binary),
              let hostPlugins = config.cniHostPlugins else { return nil }

        let conflist: String
        if let supplied = config.cniConflist, !supplied.isEmpty {
            conflist = supplied
        } else {
            try CNIRuntime.writeDefaultConflist(at: defaultConflistPath.path())
            conflist = defaultConflistPath.path()
        }
        let cache = config.stateDir.appending(component: "cni-cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return CNIRuntime(binary: binary, conflist: conflist,
                          hostPlugins: hostPlugins,
                          guestPlugins: config.cniGuestPlugins ?? "",
                          cacheDir: cache.path(),
                          execSocket: config.execSocket)
    }

    var gateway: String { "\(network.ipv4Gateway)" }
    var subnet: String { "\(network.subnet)" }

    /// How long to wait for this node's slice before giving up on it, when there
    /// are peers that would be cut off by starting anywhere else.
    ///
    /// Long enough for two attempts a full expiry window apart. It is not "a
    /// minute plus margin" any more, because the thing being waited out is not
    /// a fixed timer: asking restarts it.
    static let sliceWaitSeconds: TimeInterval = 200

    /// The gap between asking for the slice and asking again.
    ///
    /// Longer than the reservation's own expiry, because each refused ask
    /// renews it (experiment 22). Anything shorter than an expiry window turns
    /// waiting into holding.
    static let sliceRetrySeconds: TimeInterval = 95

    /// The other Macs in this cluster, as relay endpoints.
    ///
    /// Read from the peers file as well as the flag, because the file is what
    /// ferry-streamer maintains from the node list and survives a restart -- at
    /// the moment this runs nothing has talked to the API server yet, so a file
    /// written by the previous run is the only evidence a second node exists.
    /// This node's own endpoint is not a peer.
    ///
    /// Nor is any endpoint on this node's relay port at one of this Mac's own
    /// addresses. The file can hold this node under the address an earlier run
    /// advertised -- its LAN address, when this run was started with
    /// FERRY_LAN_IP=127.0.0.1 -- and matching only today's endpoint counted
    /// that as a second node, so a Mac alone in its cluster waited out the
    /// slice and then refused to start for the sake of a peer that was itself.
    /// Another profile on this Mac has a relay port of its own, so it is not
    /// caught by this.
    static func otherPeers(config: RuntimeConfig) -> [String] {
        var found = Set(config.peers)
        if let path = config.peersFile,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                found.insert(line.trimmingCharacters(in: CharacterSet.whitespaces))
            }
        }
        found.remove("")
        if let mine = config.relayEndpoint { found.remove(mine) }
        let own = localAddresses()
        found = found.filter { endpoint in
            guard let colon = endpoint.lastIndex(of: ":"),
                  UInt16(endpoint[endpoint.index(after: colon)...]) == config.relayPort else { return true }
            return !own.contains(String(endpoint[..<colon]))
        }
        return found.sorted()
    }

    /// Every IPv4 address this Mac has, loopback included.
    static func localAddresses() -> Set<String> {
        var addresses: Set<String> = ["127.0.0.1"]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return addresses }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            if let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.insert(String(cString: host))
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return addresses
    }

    /// This node's slice of the cluster network, as vmnet wants it: the gateway
    /// address and a prefix. Node 3 of 10.244.0.0/16 is 10.244.3.1/24.
    static func nodeSlice(of clusterCIDR: String, node: Int) -> String? {
        let parts = clusterCIDR.split(separator: "/")
        guard parts.count == 2, let length = Int(parts[1]), length <= 24 else { return nil }
        let octets = parts[0].split(separator: ".")
        guard octets.count == 4, node >= 0, node <= 255 else { return nil }
        return "\(octets[0]).\(octets[1]).\(node).1/24"
    }

    static func prefixLength(of cidr: String) -> Int? {
        cidr.split(separator: "/").last.flatMap { Int($0) }
    }

    /// The preferred subnet first, then alternatives for when a recent run
    /// still holds it.
    private static func subnetCandidates(preferred: String) -> [String] {
        var candidates = [preferred]
        for third in [66, 77, 88, 99, 111, 122, 133, 144, 155, 166, 177, 188, 199, 211, 222] {
            let candidate = "192.168.\(third).1/24"
            if candidate != preferred { candidates.append(candidate) }
        }
        return candidates
    }

    private func nextID(_ prefix: String) -> String {
        idCounter += 1
        return String(format: "%@%015llx", prefix, idCounter)
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000_000) }

    // MARK: - Sandboxes

    func runPodSandbox(config cfg: Runtime_V1_PodSandboxConfig) async throws -> String {
        let id = nextID("sandbox")

        // A pod may claim the reserved DNS address by annotation, so cluster
        // DNS lands where the kubelet was already told to look.
        let wantsReserved = cfg.annotations[Self.reservedAddressAnnotation] == "dns"
        let interface: any Interface
        var takesReserved = false
        if wantsReserved, let reserved = dnsInterface {
            // Held means a predecessor is still being stopped: a force delete,
            // or an etcd restore handing back a CoreDNS the kubelet has not
            // killed yet. Taking an ordinary address instead is permanent --
            // measured, CoreDNS at .8 until recreated, and every pod's resolver
            // at .2 answering nothing -- so wait for it, and past that make the
            // kubelet retry. The actor is free while this sleeps, which is what
            // lets the stop that releases it run.
            for _ in 0..<30 where dnsInterfaceInUse {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !dnsInterfaceInUse else {
                throw RuntimeFailure.busy("the cluster DNS address is still held by a stopping sandbox")
            }
            interface = reserved
            dnsInterfaceInUse = true
            takesReserved = true
        } else {
            guard let fresh = try network.createInterface(id) else {
                throw RuntimeFailure.invalid("pod network exhausted; no address available")
            }
            interface = fresh
        }
        let ip = "\(interface.ipv4Address)".split(separator: "/").first.map(String.init) ?? ""


        // eth1: the same address, with the cluster's prefix. Traffic for this
        // node's own slice matches the narrower route and leaves by eth0 on the
        // kernel datapath; everything else in the cluster leaves by the switch.
        // Both carry the same source address, so a pod is one pod wherever it is
        // talking to.
        var clusterInterface: SwitchInterface?
        if podSwitch != nil, !ip.isEmpty,
           let wide = try? CIDRv4("\(ip)/\(clusterPrefixLength)"),
           let nic = try? SwitchInterface(address: wide, mac: nil) {
            clusterInterface = nic
        }

        // The CNI chain's host half. vmnet chose the address, so this hands it
        // to CNI rather than asking for one -- upstream's `static` IPAM takes it
        // through the `ips` capability, the same mechanism portMappings uses.
        //
        // What it produces is the prevResult the guest half chains from. A CNI
        // chain has to start with something that made an interface, and on this
        // system that is the hypervisor, so ferry-vm says so and the rest of the
        // chain proceeds exactly as it would anywhere else.
        if let cni, !ip.isEmpty {
            do {
                _ = try await cni.add(sandboxID: id, stage: .host,
                                      addresses: ["\(ip)/\(clusterPrefixLength)"])
            } catch {
                FileHandle.standardError.write(
                    "warning: the host half of the CNI chain failed for \(id): \(error)\n".data(using: .utf8)!)
            }
        }

        // The pod's spec is read before the machine is made, because it decides
        // how big the machine has to be.
        //
        // CRI sends resource limits per container and never for the sandbox,
        // which suits a runtime whose containers share a machine that already
        // exists. Here the machine is created for the pod and cannot be resized
        // afterwards -- Virtualization.framework's memory balloon only shrinks a
        // guest below its boot size -- so sizing from a node-wide default meant a
        // pod with `limits.memory: 2Gi` got a 512 MiB machine, and its container
        // died of a guest OOM well inside the limit Kubernetes had granted it.
        let expected = await podContainers(
            namespace: cfg.metadata.namespace, name: cfg.metadata.name)
        let memoryVolumes = Self.memoryVolumeSizes(expected.memoryVolumes, podLimit: expected.memoryLimit)
        let vmMemory = vmMemory(forPodLimit: expected.memoryLimit, memoryVolumes: memoryVolumes)
        let vmCPUs = expected.cpuLimit > 0
            ? max(config.defaultCPUs, Int(expected.cpuLimit)) : config.defaultCPUs

        let pod: LinuxPod
        do {
            pod = try makePod(id: id, interface: interface, cfg: cfg,
                              clusterInterface: clusterInterface,
                              memoryBytes: vmMemory, cpus: vmCPUs)
        } catch {
            // No record exists yet for a stop to find, so nothing else would
            // ever hand the DNS address back.
            if takesReserved { dnsInterfaceInUse = false }
            throw error
        }
        if let clusterInterface {
            podSwitch?.attach(podID: id, fd: clusterInterface.hostFD)
        }
        // The VM is deliberately not created yet. CRI adds containers after the
        // sandbox exists, and on this hypervisor a container can only be added
        // before the VM boots -- see startContainer.

        defer { publishHostPorts() }
        sandboxes[id] = SandboxRecord(
            id: id, pod: pod,
            name: cfg.metadata.name, uid: cfg.metadata.uid,
            namespace: cfg.metadata.namespace, attempt: cfg.metadata.attempt,
            labels: cfg.labels, annotations: cfg.annotations,
            ip: ip, logDirectory: cfg.logDirectory, createdAt: Self.now(),
            // Whether this sandbox took it, not whether anyone holds it: the
            // second read made an ordinary-address CoreDNS free its
            // predecessor's reservation on stop and leak its own address.
            usesReservedAddress: takesReserved,
            interface: interface, clusterInterface: clusterInterface, config: cfg,
            expectedContainers: expected.containers,
            initContainerNames: expected.initContainers,
            volumeSubPaths: expected.volumeSubPaths,
            specImages: expected.images,
            gpuContainerNames: expected.gpuContainers,
            priority: expected.priority,
            vmMemoryBytes: vmMemory,
            vmCPUs: vmCPUs,
            memoryVolumes: memoryVolumes
        )
        return id
    }

    /// Translates a CRI security context into the framework's capability sets.
    /// Kubernetes speaks in terms of adding to and dropping from a default set,
    /// and "ALL" is legal on either side.
    private static func capabilities(for security: Runtime_V1_LinuxContainerSecurityContext) -> Containerization.LinuxCapabilities {
        if security.privileged { return .allCapabilities }

        var names = Set(Containerization.LinuxCapabilities.defaultOCICapabilities.bounding)
        let drops = security.capabilities.dropCapabilities
        if drops.contains(where: { $0.uppercased() == "ALL" }) {
            names.removeAll()
        } else {
            for drop in drops {
                if let capability = try? CapabilityName(rawValue: drop) { names.remove(capability) }
            }
        }
        let adds = security.capabilities.addCapabilities
        if adds.contains(where: { $0.uppercased() == "ALL" }) {
            return .allCapabilities
        }
        for add in adds {
            if let capability = try? CapabilityName(rawValue: add) { names.insert(capability) }
        }

        let list = Array(names)
        // Ambient is left empty: capabilities are granted to the container's
        // own process, not inherited by anything it later executes.
        return Containerization.LinuxCapabilities(
            bounding: list, effective: list, inheritable: list, permitted: list, ambient: [])
    }

    /// The default set plus a few named capabilities, for the helper binaries
    /// ferry runs inside a pod on its own behalf -- nft and the CNI plugins.
    /// The workload's own capabilities are untouched.
    static func capabilities(adding names: [String]) -> Containerization.LinuxCapabilities {
        var privileged = Containerization.LinuxCapabilities.defaultOCICapabilities
        for name in names {
            guard let capability = try? CapabilityName(rawValue: name) else { continue }
            privileged.bounding.append(capability)
            privileged.effective.append(capability)
            privileged.permitted.append(capability)
            privileged.ambient.append(capability)
        }
        return privileged
    }

    /// Asks ferry-streamer which containers the pod spec declares. A failure is
    /// not fatal: without it single-container pods behave exactly as before,
    /// only sidecars are lost.
    private func podContainers(namespace: String, name: String) async
        -> (initContainers: [String], containers: [String], gpuContainers: [String],
            priority: Int32, memoryLimit: Int64, cpuLimit: Int32,
            volumeSubPaths: [String: [String]], memoryVolumes: [String: Int64],
            images: [String])
    {
        guard !namespace.isEmpty, !name.isEmpty, let streamer else { return ([], [], [], 0, 0, 0, [:], [:], []) }
        do {
            let body = try streamer.get(path: "/pod?namespace=\(namespace)&name=\(name)")
            let decoded = try JSONDecoder().decode(PodContainers.self, from: body)
            return (decoded.initContainers ?? [], decoded.containers ?? [],
                    decoded.gpuContainers ?? [], decoded.priority ?? 0,
                    decoded.memoryLimitBytes ?? 0, decoded.cpuLimit ?? 0,
                    decoded.volumeSubPaths ?? [:], decoded.memoryVolumes ?? [:],
                    decoded.images ?? [])
        } catch {
            return ([], [], [], 0, 0, 0, [:], [:], [])
        }
    }

    /// How big the VM for a pod has to be.
    ///
    /// The pod's own limits plus room for the kernel and vminitd underneath
    /// them. Without the headroom a pod whose containers are allowed 2 GiB gets
    /// a 2 GiB machine, and the guest OOMs before the containers reach their
    /// limit -- the cgroup permits what the machine cannot supply.
    ///
    /// A pod that set no limits keeps the configured default, which is also the
    /// floor: sizing a machine below it makes nothing smaller, since guest
    /// memory is lazily backed and costs what it touches rather than what it
    /// was promised.
    ///
    /// A memory-backed emptyDir is added on top. On Linux its pages are charged
    /// to the container that wrote them and so fall inside that container's
    /// limit, and here they are too while the VM lasts -- but what is carried
    /// into a replacement VM is written by the guest agent, which no container
    /// limit covers, and the container can then use its whole limit besides.
    /// So the machine has room for both. It costs nothing until it is written.
    private func vmMemory(forPodLimit limit: Int64, memoryVolumes: [String: UInt64] = [:]) -> UInt64 {
        let volumes = memoryVolumes.values.reduce(0, +)
        guard limit > 0 else { return config.defaultMemoryBytes + volumes }
        return max(config.defaultMemoryBytes, UInt64(limit) + Self.guestMemoryHeadroom + volumes)
    }

    /// How large each memory-backed emptyDir's tmpfs is: its sizeLimit, no
    /// larger than the pod's memory limit, or the pod's limit when it set no
    /// sizeLimit -- which is how the kubelet sizes one on Linux. A pod with
    /// neither gets 0, leaving it to the guest kernel's default of half the
    /// VM; Linux would give it the node's allocatable memory, which is not a
    /// number a VM with a fixed size can honour.
    static func memoryVolumeSizes(_ volumes: [String: Int64], podLimit: Int64) -> [String: UInt64] {
        volumes.mapValues { sizeLimit in
            switch (sizeLimit > 0, podLimit > 0) {
            case (true, true): UInt64(min(sizeLimit, podLimit))
            case (true, false): UInt64(sizeLimit)
            case (false, true): UInt64(podLimit)
            case (false, false): 0
            }
        }
    }

    /// What the guest kernel, vminitd and the pod's own page cache need beyond
    /// the workload's limits. An idle pod VM touches about 103 MiB of its own
    /// memory with nothing running in it (experiment 32; 194 before it).
    static let guestMemoryHeadroom: UInt64 = 256 * 1024 * 1024

    private func makePod(id: String, interface: any Interface,
                         cfg: Runtime_V1_PodSandboxConfig,
                         clusterInterface: SwitchInterface? = nil,
                         memoryBytes: UInt64? = nil,
                         cpus: Int? = nil,
                         volumes: [BlockVolume] = [],
                         layout: PodRootfsLayout = PodRootfsLayout()) throws -> LinuxPod {
        try LinuxPod(id, vmm: VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs,
                                                     group: eventLoops)) { c in
            c.cpus = cpus ?? config.defaultCPUs
            c.volumes = volumes.map(\.podVolume) + layout.podVolumes
            // Every container reaches the VM through this, at boot or after.
            c.extensions = [PodRootfsExtension(layout: layout)]
            c.memoryInBytes = memoryBytes ?? config.defaultMemoryBytes
            // eth0 is vmnet and keeps the default route; eth1, when there is a
            // cluster, is ferry's own segment.
            c.interfaces = clusterInterface.map { [interface, $0] } ?? [interface]
            c.hostname = cfg.hostname.isEmpty ? cfg.metadata.name : cfg.hostname
            // shareProcessNamespace: kubelet asks for POD, and the framework
            // then boots a pause process as PID 1 that every container joins,
            // so a preStop that signals a sibling by PID can reach it.
            c.shareProcessNamespace = cfg.linux.securityContext.namespaceOptions.pid == .pod
            if !cfg.dnsConfig.servers.isEmpty {
                c.dns = DNS(nameservers: cfg.dnsConfig.servers,
                            domain: cfg.dnsConfig.searches.first,
                            searchDomains: cfg.dnsConfig.searches,
                            options: cfg.dnsConfig.options)
            }
        }
    }

    func stopPodSandbox(_ id: String) async throws {
        guard var record = sandboxes[id] else { throw RuntimeFailure.notFound("sandbox \(id)") }
        guard record.ready else { return }
        let wasBooted = record.booted
        // Unwind the guest half of the chain first: it runs inside the pod, so
        // it needs a kernel that is still alive and a container to exec beside.
        if wasBooted, cni != nil, !record.ip.isEmpty {
            try? await runGuestChain(.del, sandboxID: id)
        }
        for containerID in containers.values.filter({ $0.sandboxID == id }).map(\.id) {
            containers[containerID]?.state = .exited
            containers[containerID]?.finishedAt = Self.now()
        }
        if wasBooted { try? await record.pod.stop() }
        // After the stop, not before: the VM has to have let go of the image
        // before another pod's VM may attach it.
        releaseBlockVolumes(sandboxID: id)
        record.blockVolumes = []
        record.podVolumes = []
        releaseGPU(record)
        record.gpuGranted = false
        record.ready = false
        // Free the reserved DNS address as soon as the pod stops. Waiting for
        // RemovePodSandbox lets a terminated CoreDNS keep the reservation, so
        // its replacement lands on an ordinary address and the kubelet's
        // clusterDNS then points at nothing.
        if record.usesReservedAddress { dnsInterfaceInUse = false }
        podSwitch?.detach(podID: id)
        // A stopped sandbox is never started again -- the kubelet makes a new
        // one -- so the VM's end of its switch link can go with it.
        record.clusterInterface?.closeGuestSide()
        defer { publishHostPorts() }
        // The guest half of DEL already ran, above, while there was still a
        // kernel to run it in. This is the rest of the chain unwinding.
        if cni != nil, !record.ip.isEmpty {
            try? await cni?.del(sandboxID: id, stage: .host)
        }

        sandboxes[id] = record
    }

    func removePodSandbox(_ id: String) async throws {
        guard sandboxes[id] != nil else { return }
        try? await stopPodSandbox(id)
        // Normally the stop has done this already. Repeated so that no path to
        // a removed sandbox can leave a volume claimed by a pod that is gone.
        releaseBlockVolumes(sandboxID: id)
        for containerID in containers.values.filter({ $0.sandboxID == id }).map(\.id) {
            containers.removeValue(forKey: containerID)
            unlink(retainedLogPath(containerID))
        }
        // Every container's writes, current and past, went to this.
        try? FileManager.default.removeItem(atPath: scratchPath(id))
        // The reserved DNS address stays reserved across CoreDNS restarts; only
        // ordinary pod addresses go back to the allocator.
        if sandboxes[id]?.usesReservedAddress == true {
            dnsInterfaceInUse = false
        } else {
            network.releaseInterface(id)
        }
        sandboxes.removeValue(forKey: id)
    }

    func sandbox(_ id: String) throws -> SandboxRecord {
        guard let record = sandboxes[id] else { throw RuntimeFailure.notFound("sandbox \(id)") }
        return record
    }

    func listSandboxes() -> [SandboxRecord] { Array(sandboxes.values) }

    // MARK: - Service rules
    //
    // The ruleset is computed once on the host and applied inside each pod.
    // That is the whole reason there is no kube-proxy here: a pod needs the
    // rules, not a process that works them out for itself.

    /// The pod network, when ferry is running one.
    private var podSwitch: PodSwitch?
    /// The CNI runtime that runs each pod's plugin chain.
    private var cni: CNIRuntime?
    /// The cluster network's prefix length, which eth1 carries so that anything
    /// outside this node's own slice leaves by the switch. Off the slice there
    /// is no eth1, and this is the vmnet subnet's own prefix, so the address
    /// CNI is handed is the one the pod actually has.
    private var clusterPrefixLength = 16

    private var lastRuleset: Data?
    private var lastGeneration: UInt64 = 0
    /// NetworkPolicy rules, one section per pod address.
    private var policyRules: [String: String] = [:]
    private var lastPolicyGeneration: UInt64 = 0

    /// One rule kube-proxy cannot know it needs.
    ///
    /// A pod reaches a ClusterIP through its default route, which is eth0 on
    /// vmnet, so the kernel picks eth0's address as the source before anything
    /// is rewritten. kube-proxy then DNATs the destination to a pod address, and
    /// the packet correctly leaves by eth1 -- still carrying a vmnet source.
    ///
    /// On one machine that survives, because the reply finds its way back over
    /// the vmnet network the pods share. Across machines it cannot: the other
    /// Mac's pods have never heard of this one's vmnet addresses, and the reply
    /// goes nowhere.
    ///
    /// Masquerading what leaves eth1 with a source from outside the cluster
    /// network fixes it, and does so without losing anything: masquerade takes
    /// the outgoing interface's address, which is the pod's own cluster address.
    /// The peer still sees the pod it is actually talking to.
    private func ferryEgressRule() -> String? {
        guard let cidr = config.clusterCIDR else { return nil }
        return """
        add chain ip kube-proxy ferry-egress { type nat hook postrouting priority 110 ; }
        add rule ip kube-proxy ferry-egress oifname "eth1" ip saddr != \(cidr) masquerade

        """
    }

    /// SCTP between two pods on one node, which vmnet does not carry.
    ///
    /// Same-node traffic leaves by eth0, and vmnet drops IP protocol 132:
    /// measured, an SCTP association between two pods on one node timed out
    /// while the same pods reached each other across nodes, over eth1, in about
    /// a millisecond. eth1 is ferry's own switch, which never looks above the
    /// Ethernet header, and every pod on the node is on it too. So SCTP bound
    /// for the cluster network is handed to eth1 on its way out of eth0. A rule
    /// in every pod covers both directions, and the ClusterIP path, because
    /// the egress hook runs after the Service's DNAT has chosen the pod.
    ///
    /// Kept out of the Service ruleset so that a kernel without the egress hook
    /// costs SCTP and nothing else. Only with a switch, since eth1 is named.
    private func sctpDetourRule() -> String? {
        guard podSwitch != nil, let cidr = config.clusterCIDR else { return nil }
        return """
        add table netdev ferry-sctp
        delete table netdev ferry-sctp
        add table netdev ferry-sctp
        add chain netdev ferry-sctp egress { type filter hook egress device "eth0" priority 0 ; }
        add rule netdev ferry-sctp egress meta l4proto sctp ip daddr \(cidr) fwd ip to ip daddr device "eth1"

        """
    }

    /// Applies the current ruleset to one pod. Quiet on failure: a pod that
    /// cannot reach Services is worth a log line, not a failed start.
    func applyServiceRules(sandboxID: String, ruleset: Data) async {
        var payload = ruleset
        if let extra = ferryEgressRule(), let bytes = extra.data(using: .utf8) {
            payload.append(bytes)
        }
        await applyNftables(sandboxID: sandboxID, payload: payload, label: "Service")
    }

    func applyNftables(sandboxID: String, text: String, label: String) async {
        guard let payload = text.data(using: .utf8) else { return }
        await applyNftables(sandboxID: sandboxID, payload: payload, label: label)
    }

    /// Loads an nftables script into one pod's own kernel.
    ///
    /// Everything ferry does to a pod's networking goes through here: the
    /// Service rules kube-proxy rendered, and the NetworkPolicy rules meant for
    /// this pod alone. Both are text, and the pod has a kernel to put them in.
    private func applyNftables(sandboxID: String, payload: Data, label: String) async {
        guard config.nftBundlePath != nil, !payload.isEmpty else { return }
        guard let target = containers.values.first(where: {
            $0.sandboxID == sandboxID && $0.state == .running
        }) else { return }

        var launched: LinuxProcess?
        do {
            // nft needs NET_ADMIN to program the pod's kernel, and an ordinary
            // pod does not ask for it. Granting it to this process rather than
            // to the container keeps the privilege on a binary ferry ships and
            // runs, not on the workload.
            let privileged = Self.capabilities(adding: ["NET_ADMIN"])

            let process = try await exec(
                containerID: target.id,
                // Invoked through its own loader so the pod's libc is irrelevant.
                command: ["/.ferry/lib/ld-musl-aarch64.so.1",
                          "--library-path", "/.ferry/lib",
                          "/.ferry/nft", "-f", "-"],
                tty: false,
                stdin: DataReaderStream(payload),
                stdout: DiscardWriter(),
                stderr: ErrorWriter(prefix: "nft"),
                capabilities: privileged,
                asRoot: true
            )
            launched = process
            try await process.start()
            _ = try? await process.wait(timeoutInSeconds: 15)
        } catch {
            FileHandle.standardError.write(
                "warning: could not program \(label) rules in \(sandboxID): \(error)\n".data(using: .utf8)!)
        }
        // Every exec is a process in vminitd's table, its stdio pipes, a vsock
        // port and a fresh agent connection on the host, and none of it goes
        // away on exit -- only delete() gives it back. This runs for every pod
        // on every Service change, so without it a busy node leaked guest pids
        // and host descriptors until process launches began to fail ("no PID
        // data from sync pipe") and then everything else did.
        try? await launched?.delete()
    }

    enum CNIVerb { case add, del }

    /// Runs the guest half of the CNI chain for one pod.
    ///
    /// This is the half that could not run before the VM existed. It happens
    /// inside the pod, against the pod's own root netns, which is what a main
    /// plugin would have created on Linux and what the hypervisor created here.
    ///
    /// portmap is the plugin that makes the difference visible: hostPort is
    /// carried in the sandbox config, ferry never implemented it, and upstream
    /// already has.
    private func runGuestChain(_ verb: CNIVerb, sandboxID: String) async throws {
        guard let cni, config.cniGuestPlugins != nil else { return }
        guard let sandbox = sandboxes[sandboxID] else { return }
        // Any running container in the pod will do: one VM is one network
        // stack, so they all share the netns the plugin is about to program.
        guard let target = containers.values.first(where: {
            $0.sandboxID == sandboxID && $0.state == .running
        }) else { return }

        // A host port of 0 is explicitly "do not expose this", not "pick one",
        // so it is dropped here rather than turned into a rule that means
        // something else. SCTP is passed through: portmap's nftables backend
        // writes "sctp dport", and the guest kernel has SCTP. (Whether portmap
        // gets as far as writing anything is another matter; see hostPortMap.)
        let mappings = sandbox.config.portMappings
            .filter { $0.hostPort > 0 }
            .map {
                CNIPortMapping(hostPort: $0.hostPort,
                               containerPort: $0.containerPort,
                               protocol: Self.portProtocol($0.protocol),
                               hostIP: $0.hostIp.isEmpty ? nil : $0.hostIp)
            }
        switch verb {
        case .add:
            _ = try await cni.add(sandboxID: sandboxID, stage: .guest,
                                  execContainer: target.id, portMappings: mappings)
        case .del:
            try await cni.del(sandboxID: sandboxID, stage: .guest,
                              execContainer: target.id, portMappings: mappings)
        }
    }

    /// The generation last applied, so the caller can ask for something newer.
    func seenGeneration() -> UInt64 { lastGeneration }

    /// Takes a freshly fetched ruleset and puts it in every running pod.
    ///
    /// The fetch deliberately happens outside this actor. It is a blocking read
    /// held open by ferry-proxyd until a Service changes, which can be tens of
    /// seconds; doing it here would park the actor for that whole time and every
    /// CRI call behind it -- a pod would not start or stop while ferry waited
    /// for news that may never come.
    func applyRuleset(_ ruleset: Data, generation: UInt64) async {
        guard config.nftBundlePath != nil, !ruleset.isEmpty else { return }
        lastGeneration = generation
        guard ruleset != lastRuleset else { return }
        lastRuleset = ruleset
        for sandbox in sandboxes.values where sandbox.booted {
            await applyServiceRules(sandboxID: sandbox.id, ruleset: ruleset)
        }
    }

    /// The ruleset as it stands, for a pod that has just booted.
    func currentRuleset() -> Data? { lastRuleset }

    /// What ferry-netpol last said about this pod, if anything.
    func currentPolicy(forPodAt address: String) -> String? { policyRules[address] }

    func seenPolicyGeneration() -> UInt64 { lastPolicyGeneration }

    /// Takes a fresh set of policy rules and puts each pod's own section into it.
    ///
    /// A NetworkPolicy is per pod, so unlike the Service ruleset these differ
    /// from one pod to the next and cannot be broadcast. The document is split
    /// by address and each running pod gets its part.
    func applyPolicies(_ document: String, generation: UInt64) async {
        lastPolicyGeneration = generation
        var sections: [String: String] = [:]
        var address = ""
        var body = ""
        for line in document.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if !address.isEmpty { sections[address] = body }
                address = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                body = ""
            } else {
                body += line + "\n"
            }
        }
        if !address.isEmpty { sections[address] = body }

        for (podAddress, rules) in sections where policyRules[podAddress] != rules {
            policyRules[podAddress] = rules
            guard let sandbox = sandboxes.values.first(where: { $0.ip == podAddress && $0.booted })
            else { continue }
            await applyNftables(sandboxID: sandbox.id, text: rules, label: "policy")
        }
        // A pod that vanished from the document has no policy to enforce.
        for known in policyRules.keys where sections[known] == nil {
            policyRules.removeValue(forKey: known)
        }
    }

    func cacheRuleset(_ ruleset: Data, generation: UInt64) {
        guard !ruleset.isEmpty else { return }
        lastRuleset = ruleset
        lastGeneration = generation
    }

    /// Where to fetch rulesets from, for the loop that does it off-actor.
    nonisolated var proxydClient: StreamerClient? {
        config.proxydSocket.map { StreamerClient(socketPath: $0) }
    }

    nonisolated var netpolClient: StreamerClient? {
        config.netpolSocket.map { StreamerClient(socketPath: $0) }
    }

    /// Everything attach needs: the output fan-out point, the stdin feeder if
    /// the pod asked for one, and whether the container was given a terminal.
    func attachTargets(_ id: String) throws -> (output: ContainerLogFile, stdin: FrameReaderStream?, tty: Bool) {
        guard let record = containers[id] else { throw RuntimeFailure.notFound("container \(id)") }
        guard record.state == .running else {
            throw RuntimeFailure.invalid("container \(id) is not running")
        }
        guard let output = record.logFile else {
            throw RuntimeFailure.unsupported("container \(id) has no output stream to attach to")
        }
        return (output, record.stdinFeeder, record.tty)
    }

    /// The pod's address, for port forwarding. ferry-streamer dials it directly.
    /// Where the Mac can reach this pod, which is simply its address: this
    /// node's vmnet subnet is its slice of the pod network, and the Mac is on it.
    func sandboxAddress(_ id: String) -> String? { sandboxes[id]?.ip }

    static func portProtocol(_ p: Runtime_V1_Protocol) -> String {
        switch p {
        case .udp: "udp"
        case .sctp: "sctp"
        default: "tcp"
        }
    }

    private func publishHostPorts() {
        try? hostPortMap().write(
            to: config.stateDir.appending(component: "hostports"),
            atomically: true, encoding: .utf8)
    }

    /// Every hostPort a pod on this node asked for, as
    /// "<host address> <port> <protocol> <the pod's address> <container port>".
    ///
    /// This is the other half of hostPort. portmap puts the mapping inside the
    /// pod, which makes it real on the pod's own addresses; Kubernetes means
    /// the *node's* address, and the node here is the Mac. So ferry-proxy
    /// listens there and forwards to the pod.
    ///
    /// It forwards to the container port, not the host port. It used to send
    /// the host port on for portmap's rule to rewrite, which only worked when
    /// the two were equal: portmap runs nft by PATH, and /.ferry/nft needs the
    /// loader and library path ferry passes when it runs nft itself, so the
    /// rule was never written and 5001->5000 arrived at 5001.
    func hostPortMap() -> String {
        var lines: [String] = []
        for sandbox in sandboxes.values where sandbox.ready && !sandbox.ip.isEmpty {
            for mapping in sandbox.config.portMappings
            where mapping.hostPort > 0 {
                // ferry-proxy cannot serve an sctp line -- macOS has no SCTP
                // sockets -- and says so, rather than it vanishing here.
                let host = mapping.hostIp.isEmpty ? "*" : mapping.hostIp
                let proto = Self.portProtocol(mapping.protocol)
                lines.append("\(host) \(mapping.hostPort) \(proto) \(sandbox.ip) \(mapping.containerPort)")
            }
        }
        return lines.sorted().joined(separator: "\n") + "\n"
    }

    // MARK: - GPU

    /// The socket ferry-gpud bound for this pod, if this container asked for
    /// one. Nil means the container did not ask, which is the common case.
    ///
    /// Throwing here fails CreateContainer, and that is the intent: a pod that
    /// requested a GPU and silently did not get one is worse than a pod that
    /// does not start, because the failure would surface as a missing file
    /// inside the container long after the scheduler charged the node for it.
    private func gpuGrant(for sandboxID: String, containerName: String) throws -> String? {
        guard let sandbox = sandboxes[sandboxID],
              sandbox.gpuContainerNames.contains(containerName)
        else { return nil }

        guard let socket = config.gpudSocket else {
            throw RuntimeFailure.unsupported("""
                \(containerName) requests \(Self.gpuResource) but ferry-gpud is not \
                configured on this node
                """)
        }

        // Idempotent in the daemon: the kubelet retries CreateContainer, and
        // two containers in one pod may both have asked.
        let grant = try GPUClient(controlSocket: socket).grant(
            uid: sandbox.uid.isEmpty ? sandboxID : sandbox.uid,
            namespace: sandbox.namespace, name: sandbox.name,
            priority: sandbox.priority)
        sandboxes[sandboxID]?.gpuGranted = true
        print("    gpu       \(sandbox.namespace)/\(sandbox.name) -> \(grant.socket)")
        return grant.socket
    }

    /// Hands a pod's GPU socket back. Called when the pod stops, not when it is
    /// removed: a stopped pod is not using the GPU, and holding the node's only
    /// slot until garbage collection would strand it.
    private func releaseGPU(_ record: SandboxRecord) {
        guard record.gpuGranted, let socket = config.gpudSocket else { return }
        GPUClient(controlSocket: socket).revoke(uid: record.uid.isEmpty ? record.id : record.uid)
    }

    static let gpuResource = "ferry.dev/gpu"

    /// How many whole CPUs a container may use inside its pod's machine.
    ///
    /// This is not the size of the machine. The VM's vCPU count is decided once,
    /// in runPodSandbox, from the aggregate of the pod spec's limits -- CRI
    /// sends resources per container and never for the pod, so that total comes
    /// from ferry-streamer rather than from here. What this number becomes is
    /// the container's own cgroup inside the guest: Containerization turns
    /// ContainerConfiguration.cpus into cpu.max, quota over a 100ms period.
    ///
    /// Only a limit produces a number. A request is a weight and not a ceiling
    /// -- Kubernetes lets a Burstable container use idle CPU beyond what it
    /// asked for -- and a quota is the only thing this field can express, so a
    /// container with no limit is left unthrottled within the machine its pod
    /// was sized for. Passing its cpu.shares through here would quietly turn
    /// every request into a limit, and would cap a BestEffort container at one
    /// CPU: the kubelet floors shares at 2 for unset, so there is no value that
    /// means "no request".
    ///
    /// Rounds up, because whole CPUs are the only lever. A container granted
    /// 1500m and floored to one CPU is a third slower than Kubernetes said it
    /// could be, so the rounding errs towards the limit rather than under it.
    /// The machine is already sized the same way -- the pod's total comes from
    /// limits.Cpu().Value(), which rounds up too -- so this cannot ask for more
    /// than the VM has. A limit below one CPU still lands on one: the guest
    /// cannot be given a fraction of a vCPU, and over-granting a 100m sidecar
    /// is the safer direction.
    static func containerCPUs(quota: Int64, period: Int64) -> Int? {
        guard quota > 0, period > 0 else { return nil }
        return Int((quota + period - 1) / period)
    }

    /// Who a container's process runs as, in the "user[:group]" form the guest
    /// agent resolves against the container's own /etc/passwd and /etc/group.
    /// Nil leaves the framework's default, root.
    ///
    /// The image's USER used to be ignored entirely, so an image built to run
    /// as 65532 ran as root whenever the pod did not say otherwise -- the
    /// opposite of what its author asked for, and invisible from outside.
    /// Precedence is Kubernetes': runAsUser (or runAsUsername) replaces the
    /// image's user, and then the image's group goes with it, since that group
    /// belonged to a different user; runAsGroup replaces the group either way.
    /// Names are passed through rather than looked up here: the passwd file is
    /// inside the root filesystem, and the guest is where that is readable.
    static func userString(runAsUser: UInt32?, runAsGroup: UInt32?,
                           runAsUsername: String, image: String) -> String? {
        let parts = image.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let imageUser = parts.first.map(String.init) ?? ""
        let imageGroup = parts.count > 1 ? String(parts[1]) : ""

        let podNamesUser = runAsUser != nil || !runAsUsername.isEmpty
        let user = runAsUser.map(String.init)
            ?? (runAsUsername.isEmpty ? imageUser : runAsUsername)
        let group = runAsGroup.map(String.init) ?? (podNamesUser ? "" : imageGroup)

        if user.isEmpty && group.isEmpty { return nil }
        let who = user.isEmpty ? "0" : user
        return group.isEmpty ? who : "\(who):\(group)"
    }

    // MARK: - Containers

    func createContainer(
        sandboxID: String,
        config cfg: Runtime_V1_ContainerConfig
    ) async throws -> String {
        try await awaitBoot(sandboxID)
        guard sandboxes[sandboxID] != nil else { throw RuntimeFailure.notFound("sandbox \(sandboxID)") }
        let imageRef = cfg.image.image
        // The kubelet resolves an image to its ID before calling
        // CreateContainer, so the lookup has to work by digest as well as by
        // the reference the pull used.
        guard let base = rootfsCache[imageRef] ?? rootfsCache[ImageReference.normalize(imageRef)] else {
            throw RuntimeFailure.notFound("image \(imageRef) has not been pulled")
        }

        // Block-backed PersistentVolumes first, before anything is made for
        // this container: a volume another pod holds fails the call, and it
        // should fail before anything else is made for the container.
        var blockMounts: [String: (volume: BlockVolume, subPath: String)] = [:]
        let memoryVolumes = sandboxes[sandboxID]?.memoryVolumes ?? [:]
        for mount in cfg.mounts where !mount.hostPath.isEmpty && !mount.containerPath.isEmpty {
            guard let located = BlockVolume.locate(hostPath: mount.hostPath,
                                                   memory: memoryVolumes) else { continue }
            blockMounts[mount.hostPath] = located
        }
        // Every subPath this container wants of each volume, so a first format
        // can make them the way the kubelet makes a subPath on Linux: with the
        // volume root's mode. The guest agent's mkdir ignores the mode it is
        // given, so one made later comes out 0755 root and a non-root pod
        // cannot write to it.
        var subPathsByVolume: [String: [String]] = [:]
        for located in blockMounts.values where !located.subPath.isEmpty {
            subPathsByVolume[located.volume.directory, default: []].append(located.subPath)
        }
        for located in blockMounts.values {
            // And every other subPath the pod spec names for it, for the
            // containers CRI has not shown yet -- an init container's pod boots
            // before the main container's mounts are known.
            let fromSpec = sandboxes[sandboxID]?.volumeSubPaths[located.volume.name] ?? []
            let subPaths = (subPathsByVolume[located.volume.directory] ?? []) + fromSpec
            try await claimBlockVolume(located.volume, sandboxID: sandboxID, subPaths: subPaths)
            if !located.subPath.isEmpty {
                let guest = "\(located.volume.guestPath)/\(located.subPath)"
                if sandboxes[sandboxID]?.blockSubPaths.contains(guest) == false {
                    sandboxes[sandboxID]?.blockSubPaths.append(guest)
                }
            }
        }
        // A running VM takes this container if it already has the container's
        // image and every volume it mounts -- which is what a restart, and
        // most containers that arrive late, look like. Otherwise it needs a
        // device the VM cannot be given, and so a VM it can.
        if let current = sandboxes[sandboxID], current.booted,
           !current.rootfsLayout.canRun(image: base.source) || current.blockVolumes != current.podVolumes {
            try await replaceBootedPod(sandboxID, arriving: cfg.metadata.name)
        }
        // Compared rather than tracked from the claims above: a call that took
        // one volume and was then refused another has left the sandbox holding
        // a volume its LinuxPod does not have, and the retry must still add it.
        if let held = sandboxes[sandboxID], held.blockVolumes != held.podVolumes {
            try await rebuildUnbootedPod(sandboxID)
        }

        // Re-read: the record may have just been rebuilt.
        guard let sandbox = sandboxes[sandboxID] else {
            throw RuntimeFailure.notFound("sandbox \(sandboxID)")
        }

        let id = nextID("ctr")
        // The image itself, not a copy of it: it is attached to the VM
        // read-only and the container's writes land in an overlay above it.
        // Marked read-only when the pod asked for a read-only root, which the
        // framework carries into the OCI spec rather than the mount.
        let rootfs = Containerization.Mount.block(
            format: "ext4", source: base.source, destination: "/",
            options: cfg.linux.securityContext.readonlyRootfs ? ["ro"] : [])

        // Merge the pod's overrides with the image's own configuration, the way
        // Kubernetes defines it: `command` replaces ENTRYPOINT, `args` replaces
        // CMD, and anything not overridden comes from the image.
        let imageConfig = imageConfigs[imageRef] ?? imageConfigs[ImageReference.normalize(imageRef)]
        let entrypoint = cfg.command.isEmpty ? (imageConfig?.entrypoint ?? []) : cfg.command
        let commandArgs: [String]
        if !cfg.args.isEmpty {
            commandArgs = cfg.args
        } else if cfg.command.isEmpty {
            // Only inherit CMD when the pod overrode neither; a pod that sets
            // `command` alone must not pick up the image's CMD.
            commandArgs = imageConfig?.cmd ?? []
        } else {
            commandArgs = []
        }
        let combined = entrypoint + commandArgs
        let arguments = combined.isEmpty ? ["/bin/sh"] : combined

        // Image environment first so the pod's values win on conflict.
        var mergedEnv = imageConfig?.env ?? []
        for entry in cfg.envs { 
            mergedEnv.removeAll { $0.hasPrefix("\(entry.key)=") }
            mergedEnv.append("\(entry.key)=\(entry.value)")
        }
        let environment = mergedEnv
        let workingDir = cfg.workingDir.isEmpty ? (imageConfig?.workingDir ?? "") : cfg.workingDir

        // Security context and resource limits, both carried in
        // ContainerConfig.linux. The kubelet only fills that section in from
        // applyPlatformSpecificContainerConfig, which upstream builds for linux
        // and windows only; ferry's kubelet derives a darwin copy so pods get
        // their limits and capabilities. See build-kubelet.sh.
        let security = cfg.linux.securityContext
        let capabilities = Self.capabilities(for: security)
        let runAsUser = security.hasRunAsUser ? UInt32(security.runAsUser.value) : nil
        let runAsGroup = security.hasRunAsGroup ? UInt32(security.runAsGroup.value) : nil
        let supplementalGroups = security.supplementalGroups.map { UInt32(truncatingIfNeeded: $0) }
        let userString = Self.userString(runAsUser: runAsUser, runAsGroup: runAsGroup,
                                         runAsUsername: security.runAsUsername,
                                         image: imageConfig?.user ?? "")
        let memoryLimit = cfg.linux.resources.memoryLimitInBytes
        let cpuQuota = cfg.linux.resources.cpuQuota
        let cpuPeriod = cfg.linux.resources.cpuPeriod

        // The kubelet assembles volume contents on the host -- projected
        // ServiceAccount tokens, ConfigMaps, Secrets, emptyDir -- and passes
        // the directories here. Share each one into the guest over virtiofs.
        // These become VM devices, which is why they can only be attached
        // before the pod boots.
        var collected: [Containerization.Mount] = []
        for mount in cfg.mounts {
            guard !mount.hostPath.isEmpty, !mount.containerPath.isEmpty else { continue }
            guard FileManager.default.fileExists(atPath: mount.hostPath) else {
                // A path the kubelet has not created yet is a bug on our side
                // if we silently skip it, so say so rather than starting a pod
                // that is quietly missing its token.
                throw RuntimeFailure.invalid("mount source \(mount.hostPath) does not exist")
            }
            // A block-backed volume is already attached to the pod, once, and
            // mounted in the VM; each use of it is a bind mount of that mount.
            // The whole volume goes through the framework's own shared-volume
            // mount. A subPath has to name a path beneath the volume, which
            // that cannot, so it is a plain bind from the guest path.
            if let block = blockMounts[mount.hostPath] {
                let readOnly = mount.readonly ? ["ro"] : []
                if block.subPath.isEmpty {
                    collected.append(.sharedMount(
                        name: block.volume.name, destination: mount.containerPath, options: readOnly))
                } else {
                    collected.append(.any(
                        type: "none",
                        source: "\(block.volume.guestPath)/\(block.subPath)",
                        destination: mount.containerPath,
                        options: ["bind"] + readOnly))
                }
                continue
            }
            collected.append(.share(
                source: mount.hostPath,
                destination: mount.containerPath,
                options: mount.readonly ? ["ro"] : []
            ))
        }
        // Every pod gets nft, so Service rules are applied inside its own kernel
        // rather than proxied through the host. The bundle carries its own musl
        // loader, so it does not matter what the pod's image is built on.
        if let bundle = config.nftBundlePath, FileManager.default.fileExists(atPath: bundle) {
            collected.append(.share(source: bundle, destination: "/.ferry", options: ["ro"]))
        }
        // And the CNI plugins that need a kernel, at the path CNI has always
        // used for them. Nothing about them is ferry-specific: they are
        // upstream binaries, in the upstream location, run by a real runtime.
        if let plugins = config.cniGuestPlugins, FileManager.default.fileExists(atPath: plugins) {
            collected.append(.share(source: plugins, destination: CNIRuntime.guestPluginPath, options: ["ro"]))
        }

        // Immutable so it can cross into the configuration closure.
        let shares = collected

        // CRI gives a log path relative to the sandbox's log directory; the
        // kubelet reads exactly this file for `kubectl logs`.
        var writers: [ContainerLogWriter] = []
        var logFile: ContainerLogFile?
        var stdoutWriter: ContainerLogWriter?
        var stderrWriter: ContainerLogWriter?
        // ContainerConfig.logPath is relative to the sandbox log directory, but
        // ContainerStatus.logPath must be absolute -- the kubelet resolves the
        // latter directly, and a relative value makes `kubectl logs` fail with
        // a confusing lstat error.
        var absoluteLogPath = ""
        if !cfg.logPath.isEmpty && !sandbox.logDirectory.isEmpty {
            let full = URL(filePath: sandbox.logDirectory).appending(path: cfg.logPath).path()
            absoluteLogPath = full
            let file = try ContainerLogFile(path: full)
            logFile = file
            stdoutWriter = ContainerLogWriter(file: file, stream: .stdout)
            stderrWriter = ContainerLogWriter(file: file, stream: .stderr)
            writers = [stdoutWriter!, stderrWriter!]
        }
        let outWriter = stdoutWriter
        let errWriter = stderrWriter

        let stdinFeeder = cfg.stdin ? FrameReaderStream() : nil

        // A container that asked for ferry.dev/gpu gets a socket to ferry-gpud,
        // relayed into the VM over vsock. Per container, not per pod: a sidecar
        // that did not ask does not inherit it, which is measured rather than
        // assumed -- experiments/08-vsock-socket-relay.
        let gpuSocket = try gpuGrant(for: sandboxID, containerName: cfg.metadata.name)

        let configure: @Sendable (inout LinuxPod.ContainerConfiguration) throws -> Void = { c in
            c.process.arguments = arguments
            c.process.terminal = cfg.tty
            if let stdinFeeder { c.process.stdin = stdinFeeder }
            if let outWriter { c.process.stdout = outWriter }
            // A terminal is one stream: the pty merges stderr into it, and the
            // framework refuses a separate stderr alongside terminal=true --
            // which rejected every `tty: true` container outright. The log
            // records it all as stdout, as other runtimes do for a tty.
            if let errWriter, !cfg.tty { c.process.stderr = errWriter }
            c.process.capabilities = capabilities
            if let runAsUser { c.process.user.uid = runAsUser }
            if let runAsGroup { c.process.user.gid = runAsGroup }
            if let userString { c.process.user.username = userString }
            // The kubelet folds fsGroup into these, so without them fsGroup did
            // nothing: a pod that was given a volume's group could not use it.
            // vminitd adds the user's own groups from /etc/group to whatever is
            // here rather than replacing it.
            if !supplementalGroups.isEmpty { c.process.user.additionalGids = supplementalGroups }
            if !environment.isEmpty { c.process.environmentVariables = environment }
            if !workingDir.isEmpty { c.process.workingDirectory = workingDir }
            if memoryLimit > 0 { c.memoryInBytes = UInt64(memoryLimit) }
            // A CPU limit bounds the container within the pod's machine; see
            // containerCPUs for why a request deliberately does not.
            if let cpus = Self.containerCPUs(quota: cpuQuota, period: cpuPeriod) {
                c.cpus = cpus
            }
            // Append rather than replace: the defaults carry /proc, /sys and
            // the rest of the standard container filesystem.
            c.mounts.append(contentsOf: shares)
            if let gpuSocket {
                c.sockets.append(UnixSocketConfiguration(
                    source: URL(filePath: gpuSocket),
                    destination: URL(filePath: GPUClient.guestPath),
                    direction: .into))
            }
        }
        // Before the boot the container waits to be added with the rest; see
        // bootPod. After it, it joins the running VM here. A boot that began
        // while this call was suspended did not see this container, so it is
        // waited for and joined like any other.
        try await awaitBoot(sandboxID)
        guard let host = sandboxes[sandboxID] else { throw RuntimeFailure.notFound("sandbox \(sandboxID)") }
        if host.booted {
            guard host.rootfsLayout.canRun(image: base.source), host.blockVolumes == host.podVolumes else {
                throw RuntimeFailure.busy("the pod's VM booted while \(cfg.metadata.name) was being created")
            }
            try await host.pod.addContainer(id, rootfs: rootfs, configuration: configure)
            // A subPath of a volume the VM already has, new with this container.
            await makeBlockSubPaths(sandboxID)
        }

        containers[id] = ContainerRecord(
            id: id, sandboxID: sandboxID,
            name: cfg.metadata.name, attempt: cfg.metadata.attempt,
            // CRI asks for two different things here: `image` is the name the
            // pod was written with, `imageRef` identifies the bytes. The kubelet
            // has already resolved the first into the second by this point, so
            // the name is recovered from what the pull recorded -- otherwise
            // kubectl reports every container as running a bare digest.
            image: pulledImages[imageRef]?.repoTags.last ?? imageRef,
            imageRef: pulledImages[imageRef]?.id ?? imageRef,
            labels: cfg.labels, annotations: cfg.annotations,
            logPath: absoluteLogPath, createdAt: Self.now(), tty: cfg.tty,
            logWriters: writers, logFile: logFile, stdinFeeder: stdinFeeder,
            registration: ContainerRegistration(rootfs: rootfs, configure: configure),
            mounts: cfg.mounts
        )
        return id
    }

    // MARK: - Block volumes

    /// Takes a block-backed PersistentVolume for a sandbox, formatting its
    /// image the first time anything uses it. A sandbox that already holds it
    /// has nothing to do.
    ///
    /// Refuses while another pod holds it. That is the ordinary state of a
    /// Deployment's rolling update on a ReadWriteOnce claim -- the new pod is
    /// created while the old one still runs -- and the kubelet retries
    /// CreateContainer, so the new pod starts once the old one has stopped.
    /// Attaching it anyway would put one ext4 filesystem under two kernels,
    /// each caching and writing it without knowing about the other, which
    /// corrupts it.
    private func claimBlockVolume(_ volume: BlockVolume, sandboxID: String,
                                  subPaths: [String] = []) async throws {
        // A tmpfs is the VM's own: nothing to format, and nobody else's to take.
        if volume.isMemory {
            if sandboxes[sandboxID]?.blockVolumes.contains(volume) == false {
                sandboxes[sandboxID]?.blockVolumes.append(volume)
            }
            return
        }
        if let held = blockClaims[volume.directory] {
            if held.sandboxID == sandboxID { return }
            let holder = sandboxes[held.sandboxID].map { "\($0.namespace)/\($0.name)" } ?? held.sandboxID
            throw RuntimeFailure.busy("""
                volume \(volume.name) is attached to pod \(holder); a ReadWriteOnce \
                volume is a disk that only one pod VM can mount at a time, so this \
                container will start once that pod has stopped
                """)
        }
        let fd = open(volume.directory, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw RuntimeFailure.invalid("cannot open volume \(volume.directory): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw RuntimeFailure.busy("""
                volume \(volume.name) is attached by another process on this Mac; \
                it can be mounted by one pod VM at a time
                """)
        }
        // Recorded before formatting, which suspends: a second call for this
        // volume arriving meanwhile must find it taken.
        blockClaims[volume.directory] = (sandboxID, fd)
        do {
            // Off the actor: a large claim's journal is tens of megabytes of
            // zeroes to write, and every other CRI call would wait behind it.
            let image = volume.image
            let emptyDir = volume.isEmptyDir
            let formatted = try await Task.detached {
                try BlockVolume.formatIfNeeded(
                    image: image, subPaths: subPaths,
                    create: emptyDir ? BlockVolume.emptyDirCapacity : nil,
                    journalBytes: emptyDir ? BlockVolume.emptyDirJournalBytes : nil,
                    empty: emptyDir)
            }.value
            if formatted { print("    volume    formatted \(image)") }
        } catch {
            blockClaims.removeValue(forKey: volume.directory)
            close(fd)
            throw error
        }
        sandboxes[sandboxID]?.blockVolumes.append(volume)
    }

    /// Hands back every block volume a sandbox holds. Only once its VM has
    /// stopped -- the callers see to that -- since the claim is what lets
    /// another pod's VM attach the image.
    private func releaseBlockVolumes(sandboxID: String) {
        for (directory, held) in blockClaims where held.sandboxID == sandboxID {
            close(held.fd)  // releases the flock with it
            blockClaims.removeValue(forKey: directory)
        }
    }

    /// Replaces a sandbox's LinuxPod, before it has booted, with one that has
    /// every block volume the sandbox now holds.
    ///
    /// A LinuxPod's volumes are part of its configuration and cannot change,
    /// and a pod VM cannot take a device once it is running either, so the
    /// volume has to be there when the VM is made. Nothing is lost: the old
    /// LinuxPod never made a VM, and no container is added to one before it
    /// boots -- see bootPod.
    private func rebuildUnbootedPod(_ sandboxID: String) async throws {
        guard let sandbox = sandboxes[sandboxID], !sandbox.booted else { return }
        let fresh = try makePod(id: sandboxID, interface: sandbox.interface, cfg: sandbox.config,
                                clusterInterface: sandbox.clusterInterface,
                                memoryBytes: sandbox.vmMemoryBytes > 0 ? sandbox.vmMemoryBytes : nil,
                                cpus: sandbox.vmCPUs > 0 ? sandbox.vmCPUs : nil,
                                volumes: sandbox.blockVolumes)
        sandboxes[sandboxID]?.pod = fresh
        sandboxes[sandboxID]?.podVolumes = sandbox.blockVolumes
    }

    /// Archives each memory-backed emptyDir out of a sandbox's VM before it is
    /// replaced, for makeBlockSubPaths to put back once the next one boots.
    ///
    /// This is what lets a tmpfs keep the emptyDir promise that its contents
    /// outlive a container: here a container restarting, or an init container
    /// handing over to the next, is a new VM. Held in this process's memory,
    /// never written to the Mac's disk. A VM that died on its own takes its
    /// tmpfs with it, as a node that loses power does on Linux.
    private func carryMemoryVolumes(_ sandboxID: String) async {
        guard let sandbox = sandboxes[sandboxID], sandbox.booted else { return }
        let volumes = sandbox.podVolumes.filter(\.isMemory)
        guard !volumes.isEmpty else { return }
        for volume in volumes {
            do {
                let root = volume.guestPath
                let started = ContinuousClock.now
                let data = try await sandbox.pod.withVirtualMachineInstance { vm in
                    try await GuestFiles.archive(vm: vm, root: root)
                }
                sandboxes[sandboxID]?.carriedVolumes[volume.name] = data
                print("    volume    carried \(volume.name) of \(sandbox.namespace)/\(sandbox.name): "
                    + "\(data.count) bytes archived in \(ContinuousClock.now - started)")
            } catch {
                FileHandle.standardError.write(
                    "warning: could not carry \(volume.name) over to \(sandboxID)'s next VM: \(error)\n"
                        .data(using: .utf8)!)
            }
        }
    }

    /// Puts carried memory volumes back, then creates the subPath directories a
    /// pod's containers bind from, once the VM is up and its volumes are
    /// mounted. Before any container starts, so nothing in the pod can race it.
    ///
    /// A subPath already there is left as it is. A missing one is made with the
    /// volume root's mode, root-owned, which is what the kubelet does on Linux
    /// -- and not through the agent's mkdir, which would make it 0755 whatever
    /// it was asked for, so a non-root container could not write to a subPath
    /// that appeared after the volume's first format. See GuestFiles.
    ///
    /// Not fatal: a subPath the workload made into a file is still bound, and
    /// anything genuinely wrong surfaces when the container starts, with the
    /// runtime's own error.
    private func makeBlockSubPaths(_ sandboxID: String) async {
        guard let sandbox = sandboxes[sandboxID] else { return }
        let carried = sandbox.carriedVolumes
        guard !sandbox.blockSubPaths.isEmpty || !carried.isEmpty else { return }
        sandboxes[sandboxID]?.carriedVolumes = [:]
        let volumes = sandbox.podVolumes
        let paths = sandbox.blockSubPaths
        do {
            try await sandbox.pod.withVirtualMachineInstance { vm in
                for volume in volumes {
                    if let archive = carried[volume.name] {
                        do {
                            let started = ContinuousClock.now
                            try await GuestFiles.restore(vm: vm, root: volume.guestPath, archive: archive)
                            print("    volume    restored \(volume.name) in \(sandboxID): "
                                + "\(archive.count) bytes in \(ContinuousClock.now - started)")
                        } catch {
                            FileHandle.standardError.write(
                                "warning: could not restore \(volume.name) in \(sandboxID): \(error)\n"
                                    .data(using: .utf8)!)
                        }
                    }
                    let prefix = volume.guestPath + "/"
                    let subPaths = paths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
                    guard !subPaths.isEmpty else { continue }
                    let mode = try await GuestFiles.mode(vm: vm, of: volume.guestPath)
                    for subPath in subPaths {
                        _ = try? await GuestFiles.makeDirectory(vm: vm, root: volume.guestPath,
                                                                path: subPath, mode: mode)
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(
                "warning: could not create subPath directories in \(sandboxID): \(error)\n".data(using: .utf8)!)
        }
    }

    // MARK: - Pod VM

    /// Boots underway, by sandbox. A boot suspends for as long as the VM takes
    /// to come up, and the actor serves other calls meanwhile: a second start
    /// must not boot the pod again, and a container created then must not be
    /// left out of the boot that did not know about it.
    private var booting: [String: Task<Void, Error>] = [:]

    /// Waits out a boot of this sandbox that is underway. Its failure belongs
    /// to the start that asked for it; a caller here goes on to find the pod
    /// unbooted and does what it would have done anyway.
    private func awaitBoot(_ sandboxID: String) async throws {
        if let boot = booting[sandboxID] { _ = try? await boot.value }
    }

    /// Boots a sandbox's VM with every container created so far.
    ///
    /// The LinuxPod is made here rather than reused, because only now is it
    /// known which images the VM needs: each distinct one its containers run,
    /// attached read-only, and the rest of the pod spec's images too when they
    /// are already unpacked -- so a container that arrives after the boot can
    /// join the machine instead of replacing it. Then one scratch disk for all
    /// of their writes. Containers are added after create(), all by the same
    /// path a late one takes; see PodRootfs.swift.
    ///
    /// A container that cannot be added is failed on its own, the way a
    /// failed start is, rather than taking the pod's other containers with it.
    private func bootPod(_ sandboxID: String) async throws {
        guard let sandbox = sandboxes[sandboxID] else { throw RuntimeFailure.notFound("sandbox \(sandboxID)") }
        let waiting = containers.values
            .filter { $0.sandboxID == sandboxID && $0.state == .created && $0.registration != nil }
            .sorted { $0.createdAt < $1.createdAt }

        var layout = PodRootfsLayout()
        func attach(_ image: String) {
            if layout.images[image] == nil { layout.images[image] = PodRootfsLayout.imageVolume(layout.images.count) }
        }
        for record in waiting { attach(record.registration!.rootfs.source) }
        // The rest of the spec's images are a convenience, and devices are not
        // free: Virtualization.framework will not boot a VM past about 22.
        for reference in sandbox.specImages
        where layout.images.count + sandbox.blockVolumes.count < Self.imageDeviceBudget {
            if let mount = rootfsCache[reference] ?? rootfsCache[ImageReference.normalize(reference)] {
                attach(mount.source)
            }
        }
        for record in waiting {
            var probe = LinuxPod.ContainerConfiguration()
            try? record.registration!.configure(&probe)
            for mount in probe.mounts {
                if let directory = PodRootfsLayout.sharedDirectory(for: mount) {
                    layout.shares[directory] = mount.options.contains("ro")
                }
            }
        }
        let began = ContinuousClock.now
        var phases: [String] = []
        func mark(_ phase: String) {
            guard Self.tracing else { return }
            let d = (ContinuousClock.now - began).components
            phases.append("\(phase)=\(d.seconds * 1000 + d.attoseconds / 1_000_000_000_000_000)ms")
        }
        layout.scratch = PodRootfsLayout.scratchVolume
        layout.scratchPath = try await makeScratch(sandboxID)
        mark("scratch")

        let pod = try makePod(id: sandboxID, interface: sandbox.interface, cfg: sandbox.config,
                              clusterInterface: sandbox.clusterInterface,
                              memoryBytes: sandbox.vmMemoryBytes > 0 ? sandbox.vmMemoryBytes : nil,
                              cpus: sandbox.vmCPUs > 0 ? sandbox.vmCPUs : nil,
                              volumes: sandbox.blockVolumes, layout: layout)
        sandboxes[sandboxID]?.pod = pod
        sandboxes[sandboxID]?.podVolumes = sandbox.blockVolumes
        sandboxes[sandboxID]?.rootfsLayout = layout

        mark("pod")
        try await pod.create()
        mark("create")
        sandboxes[sandboxID]?.booted = true
        await makeBlockSubPaths(sandboxID)

        for record in waiting {
            do {
                try await pod.addContainer(record.id, rootfs: record.registration!.rootfs,
                                           configuration: record.registration!.configure)
            } catch {
                // Nothing will start it now, so it fails here and alone; the
                // start that asked for it reports the framework's error.
                failStart(record.id, error)
            }
        }
        mark("add")
        if Self.tracing { print("    trace     boot \(sandboxID) images=\(layout.images.count) " + phases.joined(separator: " ")) }
    }

    /// FERRY_CRI_TRACE=1: see RuntimeService.
    static let tracing = ProcessInfo.processInfo.environment["FERRY_CRI_TRACE"] == "1"

    /// How many disks bootPod may attach for images it only expects. A VM with
    /// 23 block devices does not boot (experiment 13); this leaves room for the
    /// guest's own, the scratch disk and the volumes that arrive later.
    static let imageDeviceBudget = 16

    /// A container that was never going to start, reported the way other
    /// runtimes report a failed start so it is not mistaken for a clean exit.
    private func failStart(_ id: String, _ error: Error) {
        guard containers[id]?.state == .created else { return }
        FileHandle.standardError.write("warning: could not start \(id): \(error)\n".data(using: .utf8)!)
        containers[id]?.exitCode = 128
        containers[id]?.reason = "StartError"
        containers[id]?.state = .exited
        containers[id]?.finishedAt = Self.now()
    }

    /// Takes the VM away from a sandbox so it can be booted again with a
    /// container it cannot take while running: one whose image it does not
    /// have attached, or that mounts a block volume it does not have.
    ///
    /// With nothing running there is nothing to preserve, so the old VM is
    /// stopped and the sandbox goes back to unbooted, keeping its address. With
    /// something running, the only way forward is a new sandbox, and the
    /// sandbox reports NOTREADY so the kubelet makes one -- by which time the
    /// late image is pulled and the whole set is there at boot. An ephemeral
    /// container is refused instead: debugging a pod must not restart it.
    private func replaceBootedPod(_ sandboxID: String, arriving name: String) async throws {
        guard let sandbox = sandboxes[sandboxID], sandbox.booted else { return }
        let live = containers.values.contains { $0.sandboxID == sandboxID && $0.state == .running }
        if live {
            let known = sandbox.expectedContainers + sandbox.initContainerNames
            if !sandbox.expectedContainers.isEmpty, !known.contains(name) {
                throw RuntimeFailure.unsupported("""
                    \(name) cannot join this running pod: its image is not one the pod \
                    already runs, and a pod VM cannot be given another disk while it runs. \
                    Use an image one of its containers runs: \(sandbox.specImages.joined(separator: ", "))
                    """)
            }
            sandboxes[sandboxID]?.needsRecreate = true
            print("    pod       \(sandbox.namespace)/\(sandbox.name): \(name) "
                + "needs a disk the running VM does not have; asking the kubelet to recreate the sandbox")
            throw RuntimeFailure.unsupported("""
                cannot add \(name) to a pod that is already running: its image or one of \
                its volumes is not attached to the pod's VM, and Virtualization.framework \
                cannot attach a disk to a running VM; the sandbox is marked not ready so \
                the kubelet recreates the pod
                """)
        }
        await carryMemoryVolumes(sandboxID)
        try? await sandbox.pod.stop()
        // The old containers keep their records, and with them their exit
        // codes and log paths: the kubelet reads the previous attempt's status
        // to serve `kubectl logs --previous`, and removes them itself once it
        // is done with them.
        for stale in containers.values where stale.sandboxID == sandboxID && stale.state != .exited {
            // One that never started cannot start in the new VM either.
            if stale.state == .created {
                containers[stale.id]?.exitCode = 128
                containers[stale.id]?.reason = "StartError"
            }
            containers[stale.id]?.state = .exited
            containers[stale.id]?.finishedAt = Self.now()
        }
        // Rebuilt at the size this pod was admitted with, and with its cluster
        // interface: without it the pod came back on vmnet alone, reachable
        // from this Mac and from no pod on any other. The socket pair outlives
        // the VM and stays on the switch until the sandbox is removed.
        let rebuilt = try makePod(id: sandboxID, interface: sandbox.interface,
                                  cfg: sandbox.config,
                                  clusterInterface: sandbox.clusterInterface,
                                  memoryBytes: sandbox.vmMemoryBytes > 0 ? sandbox.vmMemoryBytes : nil,
                                  cpus: sandbox.vmCPUs > 0 ? sandbox.vmCPUs : nil,
                                  volumes: sandbox.blockVolumes)
        sandboxes[sandboxID]?.pod = rebuilt
        sandboxes[sandboxID]?.podVolumes = sandbox.blockVolumes
        sandboxes[sandboxID]?.rootfsLayout = PodRootfsLayout()
        sandboxes[sandboxID]?.booted = false
        // A new kernel has none of the old one's portmap rules.
        sandboxes[sandboxID]?.cniChainDone = false
    }

    /// Scratch disks, and the per-container root clones of the runtime before
    /// them, that a previous run left behind. No VM of this process can hold
    /// one yet, and every one of them is garbage.
    private func sweepContainerDisks() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: config.stateDir.path()) else { return }
        for name in names where name.hasSuffix(".ext4")
            && (name.hasSuffix("-scratch.ext4") || (name.hasPrefix("ctr") && !name.contains("-"))
                || (name.hasPrefix("scratch-template") && name != Self.scratchTemplateName)) {
            try? FileManager.default.removeItem(at: config.stateDir.appending(component: name))
        }
    }

    private func scratchPath(_ sandboxID: String) -> String {
        config.stateDir.appending(component: "\(sandboxID)-scratch.ext4").path()
    }

    /// A formatted, empty scratch disk made once and cloned for every pod,
    /// which on APFS is a clonefile and costs nothing measurable: formatting
    /// one per pod would put the formatter in front of every boot.
    private var scratchTemplate: Task<String, Error>?
    /// Kept across restarts; named for what is in it, so a template of another
    /// shape is never cloned for this one.
    static let scratchTemplateName = "scratch-template-\(scratchCapacity >> 30)g-\(PodRootfsLayout.scratchSlots)-nojournal.ext4"

    /// How much a pod's containers may write outside their volumes, between
    /// them. Sparse: the Mac spends what they write, not this.
    static let scratchCapacity: UInt64 = 16 * 1024 * 1024 * 1024

    /// A fresh scratch disk for a sandbox's VM, replacing any it had: a new VM
    /// starts every container from its image again, and nothing in the old
    /// one's writes belongs to it.
    private func makeScratch(_ sandboxID: String) async throws -> String {
        let template: Task<String, Error>
        if let made = scratchTemplate {
            template = made
        } else {
            let path = config.stateDir.appending(component: Self.scratchTemplateName).path()
            template = Task.detached { try Self.formatScratchTemplate(at: path) }
            scratchTemplate = template
        }
        let source: String
        do {
            source = try await template.value
        } catch {
            scratchTemplate = nil
            throw error
        }
        let destination = scratchPath(sandboxID)
        try? FileManager.default.removeItem(atPath: destination)
        try FileManager.default.copyItem(atPath: source, toPath: destination)
        return destination
    }

    /// Formatted under another name and moved into place, so a template left
    /// half-written by a process that died is never cloned.
    private static func formatScratchTemplate(at path: String) throws -> String {
        if FileManager.default.fileExists(atPath: path) { return path }
        let partial = path + ".partial"
        try? FileManager.default.removeItem(atPath: partial)
        try PodRootfsLayout.formatScratch(at: partial, capacity: scratchCapacity)
        try FileManager.default.moveItem(atPath: partial, toPath: path)
        return path
    }

    func startContainer(_ id: String) async throws {
        guard let record = containers[id] else { throw RuntimeFailure.notFound("container \(id)") }
        // Started already, as one that was waiting for the boot.
        if record.state == .running { return }
        try await awaitBoot(record.sandboxID)
        guard var sandbox = sandboxes[record.sandboxID] else {
            throw RuntimeFailure.notFound("sandbox \(record.sandboxID)")
        }

        // The spec is read at RunPodSandbox, and under load that read can fail
        // -- ferry-streamer busy, or the API server slow to answer. Without it
        // the VM boots on the first start and any later container is locked
        // out, so it is worth one more try before the boot it would decide.
        if !sandbox.booted, sandbox.expectedContainers.isEmpty {
            let again = await podContainers(namespace: sandbox.namespace, name: sandbox.name)
            if !again.containers.isEmpty {
                sandboxes[record.sandboxID]?.expectedContainers = again.containers
                sandboxes[record.sandboxID]?.initContainerNames = again.initContainers
                sandboxes[record.sandboxID]?.volumeSubPaths = again.volumeSubPaths
                sandboxes[record.sandboxID]?.specImages = again.images
            }
            // Re-read: the actor may have moved on while the spec was fetched.
            guard let current = sandboxes[record.sandboxID] else {
                throw RuntimeFailure.notFound("sandbox \(record.sandboxID)")
            }
            sandbox = current
        }

        if !sandbox.booted {
            // The kubelet works through a pod's containers one at a time --
            // create, start, create, start -- and a running VM can take a new
            // container only if it already has that container's image and
            // volumes attached, since those are disks. So the boot waits until
            // the pod's whole regular container set has been created, and the
            // VM has every image and volume they use.
            //
            // Init containers are exempt: the kubelet runs them one at a time
            // by design, each exiting before the next is created. The VM boots
            // with the first, attaching every image of the spec it can, and
            // what comes after joins it -- or, needing a disk it does not
            // have, gets a VM of its own; see replaceBootedPod.
            let isInit = sandbox.initContainerNames.contains(record.name)
            let expected = sandbox.expectedContainers
            // Exited ones do not count: a rebuilt VM keeps the records of the
            // attempts before it (for `kubectl logs --previous`), and those are
            // not in this machine and never will be.
            let created = Set(containers.values
                .filter { $0.sandboxID == record.sandboxID && $0.state != .exited }
                .map(\.name))
            let complete = expected.isEmpty || isInit || expected.allSatisfy { created.contains($0) }

            if !complete {
                // Report success and start it once the VM is up. The kubelet
                // polls container status, so it sees the container running a
                // moment later rather than being told it failed.
                sandboxes[record.sandboxID]?.pendingStart.append(id)
                return
            }

            let sandboxID = record.sandboxID
            let boot = Task { try await self.bootPod(sandboxID) }
            booting[sandboxID] = boot
            do {
                try await boot.value
                booting[sandboxID] = nil
            } catch {
                booting[sandboxID] = nil
                throw error
            }
            guard let up = sandboxes[record.sandboxID] else {
                throw RuntimeFailure.notFound("sandbox \(record.sandboxID)")
            }
            sandbox = up

            for waiting in up.pendingStart where waiting != id && containers[waiting]?.state == .created {
                do {
                    try await start(waiting, in: up.pod)
                } catch {
                    failStart(waiting, error)
                }
            }
            sandboxes[record.sandboxID]?.pendingStart = []
        }

        try await start(id, in: sandbox.pod)

        // A pod cannot reach a Service until its own kernel has the rules, and
        // it should not be reachable past its policy before it has those either.
        let sandboxID = record.sandboxID
        let address = sandboxes[sandboxID]?.ip ?? ""
        if let ruleset = lastRuleset {
            Task { [weak self] in await self?.applyServiceRules(sandboxID: sandboxID, ruleset: ruleset) }
        }
        if let policy = policyRules[address] {
            Task { [weak self] in
                await self?.applyNftables(sandboxID: sandboxID, text: policy, label: "policy")
            }
        }
        if let detour = sctpDetourRule() {
            Task { [weak self] in await self?.applyNftables(sandboxID: sandboxID, text: detour, label: "SCTP") }
        }
        // And the rest of the pod's CNI chain, which needed a booted kernel.
        // Detached for the same reason the rules are: it dials back into this
        // process's own exec socket, and holding the actor across that would
        // wait on a reply only this actor can send.
        if sandboxes[sandboxID]?.cniChainDone != true {
            sandboxes[sandboxID]?.cniChainDone = true
            // The pod can serve its hostPorts now, so tell the host edge.
            publishHostPorts()
            Task { [weak self] in
                do {
                    try await self?.runGuestChain(.add, sandboxID: sandboxID)
                } catch {
                    FileHandle.standardError.write(
                        "warning: the pod half of the CNI chain failed in \(sandboxID): \(error)\n".data(using: .utf8)!)
                    // Tried again at the next start. The VM now outlives its
                    // init containers, and the chain runs beside whichever
                    // container is running -- one that may exit under it.
                    await self?.retryGuestChain(sandboxID)
                }
            }
        }
    }

    private func retryGuestChain(_ sandboxID: String) {
        sandboxes[sandboxID]?.cniChainDone = false
    }

    /// Containers between asking the VM to start them and hearing back. The
    /// start that booted a pod starts the ones that were waiting for it, and
    /// the kubelet may be starting one of those itself; one of them wins.
    private var starting: Set<String> = []

    private func start(_ id: String, in pod: LinuxPod) async throws {
        guard containers[id]?.state == .created, starting.insert(id).inserted else { return }
        defer { starting.remove(id) }
        try await pod.startContainer(id)
        markStarted(id, pod: pod)
    }

    private func markStarted(_ id: String, pod: LinuxPod) {
        containers[id]?.state = .running
        containers[id]?.startedAt = Self.now()

        // Reap asynchronously so the exit code is available to ContainerStatus
        // without the kubelet having to ask the pod directly.
        //
        // Then give back what the container held in the guest -- its root
        // overlay, its process in the agent, the host's vsock ports for its
        // stdio -- now, while the VM runs on: the kubelet's restart of it is a
        // new container beside it, not a new VM that would take it all away.
        // Stopping an exited container sends no signal to anything.
        Task { [weak self] in
            let status = try? await pod.waitContainer(id)
            await self?.recordExit(id, code: status?.exitCode ?? -1)
            try? await pod.stopContainer(id)
        }
    }

    /// The first exit recorded is the one kept: a container stopped by the
    /// kubelet is recorded by both the stop and its reaper.
    private func recordExit(_ id: String, code: Int32) {
        guard let record = containers[id], record.state != .exited else { return }
        // Flush whatever the container wrote without a trailing newline.
        for writer in containers[id]?.logWriters ?? [] { try? writer.close() }
        containers[id]?.logFile?.close()
        containers[id]?.logFile?.ended(exitCode: code)
        retainLog(id)
        containers[id]?.state = .exited
        containers[id]?.exitCode = code
        containers[id]?.finishedAt = Self.now()
    }

    /// SIGTERM, then SIGKILL once the grace period is up, the way the kubelet
    /// means `timeout`. LinuxPod's own stop sends SIGKILL at once, and this
    /// used to be only that -- so no container was ever asked to shut down,
    /// and a database lost whatever it had not flushed on every pod deletion.
    /// Matters more now that containers restart inside a running pod, where
    /// a liveness failure is a StopContainer and nothing else.
    func stopContainer(_ id: String, timeout: Int64) async throws {
        guard let record = containers[id] else { throw RuntimeFailure.notFound("container \(id)") }
        guard record.state == .running else { return }
        var code: Int32 = 128 + 9
        if let sandbox = sandboxes[record.sandboxID] {
            if timeout > 0, (try? await sandbox.pod.killContainer(id, signal: .term)) != nil,
               let status = try? await sandbox.pod.waitContainer(id, timeoutInSeconds: timeout) {
                code = status.exitCode
            }
            try? await sandbox.pod.stopContainer(id)
        }
        recordExit(id, code: code)
    }

    /// The kubelet removes a container's log before the container, and it
    /// removes the second-newest dead container of a pod as soon as the newest
    /// dies -- while the pod's status, until the kubelet's next sync, still
    /// names that one as the last to terminate. `kubectl logs --previous` in
    /// that window asked ContainerStatus for a container that was gone and
    /// failed. So a removed container that has exited stays answerable for a
    /// minute, under the log link retainLog made, then goes for good.
    func removeContainer(_ id: String) async throws {
        guard var record = containers[id] else { return }
        if record.state == .running { try? await stopContainer(id, timeout: 0) }
        containers.removeValue(forKey: id)
        // What it wrote goes too, while the pod lives on; a pod being torn down
        // takes its whole scratch disk with it, so there is nothing to do.
        if let sandbox = sandboxes[record.sandboxID], sandbox.booted, sandbox.ready, !sandbox.needsRecreate {
            let pod = sandbox.pod
            Task.detached {
                let provider = try? await pod.withVirtualMachineInstance { vm in
                    (vm as? VZVirtualMachineInstance)?.hotplugProvider as? PodRootfsProvider
                }
                await provider?.discard(id: id)
            }
        }
        let retained = retainedLogPath(id)
        guard FileManager.default.fileExists(atPath: retained) else { return }
        record.state = .exited
        record.logPath = retained
        record.logWriters = []
        record.logFile = nil
        record.stdinFeeder = nil
        record.registration = nil
        removedContainers[id] = record
        Task { [weak self] in
            try? await Task.sleep(for: Self.removedContainerTTL)
            await self?.forgetRemoved(id)
        }
    }

    private func forgetRemoved(_ id: String) {
        removedContainers.removeValue(forKey: id)
        unlink(retainedLogPath(id))
    }

    /// Where a stopped container's log is kept once the kubelet has deleted
    /// its own name for it. Under the state directory, outside every path the
    /// kubelet globs when it cleans a container's logs up.
    static let retainedLogDirectory = "logs"
    private func retainedLogPath(_ id: String) -> String {
        config.stateDir.appending(component: Self.retainedLogDirectory).appending(component: "\(id).log").path()
    }

    /// A hard link to a container's log, made as it exits: one link(2), no
    /// copy, and it costs no space until the kubelet deletes the original.
    /// Nothing is written to the log after exit, so the link is the whole log.
    private func retainLog(_ id: String) {
        guard let path = containers[id]?.logPath, !path.isEmpty else { return }
        let retained = retainedLogPath(id)
        unlink(retained)
        link(path, retained)
    }

    /// Runs a command in a container's VM for `kubectl exec`. An empty command
    /// means attach, which is not supported yet -- the framework exposes no way
    /// to reattach to a process that is already running.
    func exec(
        containerID: String,
        command: [String],
        tty: Bool,
        stdin: (any ReaderStream)?,
        stdout: any Writer,
        stderr: any Writer,
        capabilities: Containerization.LinuxCapabilities? = nil,
        environment: [String]? = nil,
        asRoot: Bool = false
    ) async throws -> LinuxProcess {
        guard let record = containers[containerID] else {
            throw RuntimeFailure.notFound("container \(containerID)")
        }
        guard let sandbox = sandboxes[record.sandboxID], sandbox.booted else {
            throw RuntimeFailure.invalid("container \(containerID) is not running")
        }
        guard !command.isEmpty else {
            throw RuntimeFailure.unsupported("attach is not implemented; use kubectl exec")
        }

        idCounter += 1
        let processID = String(format: "exec%012llx", idCounter)
        return try await sandbox.pod.execInContainer(containerID, processID: processID) { config in
            config.arguments = command
            config.terminal = tty
            config.stdin = stdin
            config.stdout = stdout
            // With a TTY there is one stream, and the client expects everything
            // on stdout; sending stderr separately would interleave badly.
            config.stderr = tty ? nil : stderr
            if let capabilities { config.capabilities = capabilities }
            if let environment { config.environmentVariables = environment }
            // nft has to be root inside the pod whatever the workload runs as.
            // A hardened pod -- non-root, every capability dropped -- cannot
            // lend NET_ADMIN to anything, so an exec that inherits its user
            // cannot program the pod's kernel. That is not ferry's privilege to
            // give away either: it applies to this one process, which is a
            // binary ferry ships and runs, and leaves the workload untouched.
            //
            // Numeric rather than "root": the guest resolves this string
            // against the image's /etc/passwd, and a distroless or scratch
            // image has none -- which fails a name lookup but not a uid.
            if asRoot {
                config.user = ContainerizationOCI.User(uid: 0, gid: 0, additionalGids: [], username: "0:0")
            }
        }
    }

    func reopenContainerLog(_ id: String) throws {
        guard let record = containers[id] else { throw RuntimeFailure.notFound("container \(id)") }
        try record.logFile?.reopen()
    }

    /// CPU and memory for containers, read from the cgroups inside their own VMs.
    ///
    /// The kubelet tolerates an empty answer here, which is why ferry gave one
    /// for a long time. metrics-server does not: it scrapes the kubelet, finds
    /// nothing, and reports "no metrics to serve" -- so `kubectl top` and every
    /// HorizontalPodAutoscaler stay broken until something real is returned.
    ///
    /// Each pod is a VM with a Linux kernel, so its containers have ordinary
    /// cgroups; the guest agent reads them and the framework hands them back.
    func containerStatistics(ids: [String]) async -> [(id: String, stats: ContainerStatistics)] {
        var out: [(String, ContainerStatistics)] = []
        // Group by sandbox: one call per pod rather than one per container.
        var bySandbox: [String: [String]] = [:]
        for id in ids {
            guard let record = containers[id], record.state == .running else { continue }
            bySandbox[record.sandboxID, default: []].append(id)
        }
        for (sandboxID, containerIDs) in bySandbox {
            guard let sandbox = sandboxes[sandboxID], sandbox.booted else { continue }
            guard let statistics = try? await sandbox.pod.statistics(containerIDs: containerIDs)
            else { continue }
            for entry in statistics { out.append((entry.id, entry)) }
        }
        return out
    }

    func runningContainerIDs() -> [String] {
        containers.values.filter { $0.state == .running }.map(\.id)
    }

    func container(_ id: String) throws -> ContainerRecord {
        guard let record = containers[id] ?? removedContainers[id] else {
            throw RuntimeFailure.notFound("container \(id)")
        }
        return record
    }

    func listContainers() -> [ContainerRecord] { Array(containers.values) }

    // MARK: - Images

    /// Takes images from an OCI layout on disk instead of a registry.
    ///
    /// This is how someone runs code they have just built. Everything else in
    /// ferry comes from a registry, which is fine for busybox and useless for
    /// the thing you are working on -- `minikube image load` and `kind load
    /// docker-image` exist for exactly this reason.
    ///
    /// The image is registered under the name it carries, so a manifest that
    /// says `myapp:dev` keeps saying that. Pulling is what has to be avoided:
    /// the kubelet is told the image is present, and `imagePullPolicy: Never`
    /// or `IfNotPresent` keeps it from going to look for a registry that has
    /// never heard of it.
    func loadImages(from directory: String) async throws -> [String] {
        guard !directory.isEmpty else {
            throw RuntimeFailure.invalid("no directory to load from")
        }
        let platform = NodeLayout.platform
        // Trimmed to this node's platform first; see ImageLayout.swift for the
        // `docker save` archive that made this necessary.
        let scratch = config.stateDir.appending(component: "load-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let layout = try NodeLayout.prepare(source: URL(filePath: directory), scratch: scratch)
        let images: [Containerization.Image]
        do {
            images = try await store.load(from: layout)
        } catch {
            throw RuntimeFailure.invalid(
                "could not load \(directory) for \(platform.description): \(error)")
        }
        var loaded: [String] = []
        for image in images {
            // Unpack now rather than at first use: a pod that has to wait for a
            // root filesystem to be built looks like a pod that is stuck.
            let canonical = ImageReference.normalize(image.reference)
            _ = try? await cache(image, as: Set([image.reference, canonical]),
                                 canonical: canonical, platform: platform)
            loaded.append(image.reference)
        }
        guard !loaded.isEmpty else {
            throw RuntimeFailure.invalid("no images found in \(directory)")
        }
        recordLoaded(adding: loaded.map(ImageReference.normalize), removing: [])
        return loaded
    }

    /// The names that came from a load rather than a registry, kept beside the
    /// store as loaded-images, one a line.
    ///
    /// For ferry-registry, which serves them to machines. It is started only
    /// when FERRY_MACHINE_REGISTRY is set, and an image loaded before then has
    /// to be found in this store once it is -- but only a loaded one: an image
    /// this runtime pulled, served from the Mac, would keep a machine on
    /// whatever this Mac last saw of a mutable tag. See ferry-registry's
    /// importCRI.
    private func recordLoaded(adding: [String], removing: [String]) {
        let path = config.stateDir.appending(component: "loaded-images")
        let current = ((try? String(contentsOf: path, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        var names = current.filter { !removing.contains($0) && !adding.contains($0) }
        names += adding
        guard names != current else { return }
        try? (names.joined(separator: "\n") + (names.isEmpty ? "" : "\n"))
            .write(to: path, atomically: true, encoding: .utf8)
    }

    /// Puts back what the kubelet was told about images before a restart.
    ///
    /// The store on disk survives `ferry down`, and so do the unpacked root
    /// filesystems beside it, but what this process knows about them lived
    /// only in memory -- so after a restart ImageStatus answered "absent" for
    /// everything, the kubelet went to a registry, and an image that only ever
    /// came from `ferry image load` failed as ErrImagePull in every pod that
    /// used it. Registered under the same keys a pull or load uses. The root
    /// filesystem is reused when its file is still there, and unpacked again
    /// only when it is not.
    private func rehydrateImages() async {
        guard let images = try? await store.list() else { return }
        let initImage = Set([config.initImage, ImageReference.normalize(config.initImage)])
        var restored = 0
        for image in images {
            let canonical = ImageReference.normalize(image.reference)
            // vminit is the guest agent's image, not a workload's.
            guard !initImage.contains(image.reference), !initImage.contains(canonical) else { continue }
            if (try? await cache(image, as: Set([image.reference, canonical]),
                                 canonical: canonical, platform: NodeLayout.platform)) != nil {
                restored += 1
            }
        }
        if restored > 0 { print("    images    \(restored) restored from the image store") }
        sweepImageDisks()
    }

    /// Removes every unpacked root filesystem that no image in the store
    /// resolves to, once they have all been restored.
    ///
    /// cache() collects the disk an image leaves behind when it is replaced,
    /// but only while this process is running. What it cannot see is what an
    /// older ferry-cri left: root filesystems used to be named after the image
    /// rather than its digest, so an upgrade unpacked every image again as
    /// image-sha256_<digest>.ext4 and left the old image-<name>.ext4 beside it
    /// -- measured at 29 of them, 15 GiB, on a Mac with 32 images. A disk is
    /// only ever reached through rootfsCache, so one it does not name is
    /// garbage: nothing can clone it.
    private func sweepImageDisks() {
        // By name: every one of them is made in the state directory.
        let live = Set(rootfsCache.values.map { ($0.source as NSString).lastPathComponent })
        let directory = config.stateDir.path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        var freed: UInt64 = 0
        var removed = 0
        for name in names where name.hasPrefix("image-") && name.hasSuffix(".ext4") && !live.contains(name) {
            let path = (directory as NSString).appendingPathComponent(name)
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64) ?? 0
            if (try? FileManager.default.removeItem(atPath: path)) != nil {
                freed += size
                removed += 1
            }
        }
        if removed > 0 {
            print("    images    \(removed) unused root filesystems removed (\(freed / 1_048_576) MiB apparent)")
        }
    }

    func pullImage(_ reference: String) async throws -> String {
        let platform = NodeLayout.platform
        // The registry is asked for the fully qualified name; every cache is
        // keyed by both that and whatever the manifest actually said, so a pod
        // written as `busybox:1.36` finds the image it just pulled.
        let canonical = ImageReference.normalize(reference)
        // This Mac's registry first, which is how a loaded image reaches every
        // node in the cluster. See ImageMirror.swift.
        var image = await ImageMirror.pull(canonical, platform: platform, into: store)
        if image == nil {
            image = try await store.pull(reference: canonical, platform: platform,
                                         insecure: ImageReference.insecure(canonical))
            // From a real registry, so the name is that registry's now, whatever
            // it was loaded as before. One from the mirror above was loaded on
            // some node, and stays a loaded image.
            recordLoaded(adding: [], removing: [canonical])
        }
        guard let image else { throw RuntimeFailure.invalid("pull \(canonical) produced no image") }
        return try await cache(image, as: Set([reference, canonical]), canonical: canonical,
                               platform: platform)
    }

    /// How big a filesystem an image needs.
    ///
    /// This was a flat 2 GiB, which is generous for busybox and too small for
    /// anything real: `python:3.12` unpacks to about 1.4 GiB and leaves no room
    /// for a container to write, and an image past roughly 1.5 GiB could not be
    /// run at all -- which is most of the ML images anyone would want a GPU for.
    ///
    /// A manifest reports compressed layer sizes, and unpacked is larger by a
    /// factor that has to be guessed at because nothing in the manifest records
    /// it. Measured on arm64: python:3.12-slim 45 MiB compressed to 145 MiB
    /// unpacked (3.2x), python:3.12 381 MiB to 1070 MiB (2.8x). Four is that
    /// with room to be wrong.
    ///
    /// Plus 2 GiB for the container's own writes, which is what an image got to
    /// itself under the old flat figure, and never below that old figure so
    /// small images are unaffected.
    ///
    /// Over-provisioning is close to free: the file is sparse and costs what is
    /// written to it rather than what it may hold.
    static let rootfsCompressionFactor: UInt64 = 4

    static func rootfsCapacity(for image: Containerization.Image,
                               platform: ContainerizationOCI.Platform) async -> UInt64 {
        let floor = UInt64(2.gib())
        guard let manifest = try? await image.manifest(for: platform) else { return floor }
        let compressed = manifest.layers.reduce(Int64(0)) { $0 + $1.size }
        guard compressed > 0 else { return floor }
        return max(floor, UInt64(compressed) * rootfsCompressionFactor + UInt64(2.gib()))
    }

    /// Unpacks an image to a root filesystem and records it where the kubelet
    /// will look. Shared by pulling and loading, which differ only in where the
    /// image came from.
    private func cache(_ image: Containerization.Image, as keys: Set<String>, canonical: String,
                       platform: ContainerizationOCI.Platform) async throws -> String {

        // A root filesystem belongs to the image's content, not to its name.
        //
        // This used to ask `rootfsCache[canonical] == nil` and unpack to
        // image-<name>.ext4. A tag is not a stable identifier: `myapp:dev`
        // built twice is two different images, and both the cache key and the
        // file name collided, so the second load reused the first image's
        // root filesystem. The build, the load and `ferry image list` all
        // reported the new image, and the pod ran the old one -- measured, with
        // a marker file: built and loaded VERSION-TWO, the pod printed
        // VERSION-ONE. That is the loop this feature exists to serve, so it is
        // keyed by digest here and the name is an alias for it.
        let identity = image.digest.isEmpty ? canonical : image.digest
        let previous = rootfsCache[canonical]

        if rootfsCache[identity] == nil {
            let safe = identity.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let path = config.stateDir.appending(component: "image-\(safe).ext4")
            let mount: Containerization.Mount
            do {
                mount = try await EXT4Unpacker(capacityInBytes: Self.rootfsCapacity(for: image, platform: platform))
                    .unpack(image, for: platform, at: path)
            } catch let error as ContainerizationError where error.code == .exists {
                mount = .block(format: "ext4", source: path.path(), destination: "/", options: [])
            }
            rootfsCache[identity] = mount
        }
        for key in keys { rootfsCache[key] = rootfsCache[identity] }

        // The image the name used to point at, once no name points at it.
        //
        // Without this an edit-rebuild loop leaves one ext4 per build on disk,
        // each the size of the unpacked image -- measured at 4 GiB a build for
        // a python image, which fills a disk in an afternoon.
        //
        // "No name points at it" is the test, not "nothing points at it". The
        // superseded image keeps its own digest key, and that key is a
        // reference, so asking whether anything at all still resolves to the
        // old rootfs answers yes forever and nothing is ever collected. What
        // makes it garbage is that no *tag* names it any more: an image you can
        // only reach by a digest you no longer have written down anywhere is
        // not reachable.
        //
        // A running pod does not need the name either. Its VM attached the
        // file when it was made and holds it open, so removing the path leaves
        // that pod's disk as it was -- and a restart there looks the image up
        // by its digest, which the new pull or load answers to.
        if let stale = previous, stale.source != rootfsCache[identity]?.source {
            let namedBy = rootfsCache.filter {
                !$0.key.hasPrefix("sha256:") && $0.value.source == stale.source
            }
            if namedBy.isEmpty {
                let orphaned = rootfsCache.filter { $0.value.source == stale.source }.map(\.key)
                for key in orphaned {
                    rootfsCache.removeValue(forKey: key)
                    imageConfigs.removeValue(forKey: key)
                    pulledImages.removeValue(forKey: key)
                }
                try? FileManager.default.removeItem(atPath: stale.source)
            }
        }
        // The digest is now `identity` above, so it is a key on every path
        // rather than only on the one that unpacks. It has to be: the kubelet
        // resolves an image to its ID once it knows one and passes that to
        // CreateContainer, so the digest is the key the *second* pod from an
        // image is looked up by, while pulledImages below records it
        // unconditionally. When the two disagreed, a pod that had run once
        // failed with "image sha256:... has not been pulled" while the image
        // sat in the store with its ext4 beside it.

        let imageConfig = try? await image.config(for: platform).config
        if let imageConfig {
            for key in keys { imageConfigs[key] = imageConfig }
            if !image.digest.isEmpty { imageConfigs[image.digest] = imageConfig }
        }

        // The kubelet rejects an image whose id or size is unset -- it reports
        // ImageInspectError and the pod never starts.
        //
        // Size is the image's content as the registry described it: the config
        // and the layers, compressed, which is what containerd reports and what
        // anyone comparing against `docker images` or a registry expects. It
        // used to be the size of the unpacked ext4 file, and that is a sparse
        // file whose length is its capacity -- never below the 2 GiB floor in
        // rootfsCapacity -- so every small image reported exactly 2176 MiB and
        // image GC could not tell busybox from python. The file's allocated
        // blocks are the fallback when the manifest cannot be read.
        let digest = image.digest.isEmpty ? canonical : image.digest
        var size: UInt64 = 0
        if let manifest = try? await image.manifest(for: platform) {
            let bytes = manifest.layers.reduce(manifest.config.size) { $0 + $1.size }
            size = UInt64(max(bytes, 0))
        } else if let mount = rootfsCache[canonical] {
            var st = stat()
            if stat(mount.source, &st) == 0 { size = UInt64(st.st_blocks) * 512 }
        }

        var entry = Runtime_V1_Image()
        entry.id = digest
        entry.repoTags = Array(keys).sorted()
        entry.repoDigests = image.digest.isEmpty ? [] : ["\(canonical)@\(image.digest)"]
        entry.size = max(size, 1)
        // Who the image runs as, for the kubelet's runAsNonRoot check. A
        // numeric user is a uid it can judge; a name is passed as a username,
        // which the kubelet refuses under runAsNonRoot because it cannot verify
        // it -- the same answer containerd gives, and the safe one.
        let imageUser = (imageConfig?.user ?? "")
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        if let uid = Int64(imageUser) {
            var value = Runtime_V1_Int64Value()
            value.value = uid
            entry.uid = value
        } else if !imageUser.isEmpty {
            entry.username = imageUser
        }
        for key in keys { pulledImages[key] = entry }
        if !image.digest.isEmpty { pulledImages[image.digest] = entry }
        return digest
    }

    func imageStatus(_ reference: String) -> Runtime_V1_Image? {
        pulledImages[reference] ?? pulledImages[ImageReference.normalize(reference)]
    }
    /// One entry per image, not per name: pulledImages holds each image under
    /// its tag, its normalized reference and its digest, and listing the
    /// dictionary's values put every image into node.status.images two or
    /// three times over.
    func listImages() -> [Runtime_V1_Image] {
        var seen = Set<String>()
        return pulledImages.values.filter { seen.insert($0.id).inserted }
    }

    /// Removes an image: every name it is known by, and the root filesystem.
    ///
    /// This used to remove the key it was handed and the normalised form of it,
    /// and nothing else -- which left the store in a state no caller could make
    /// sense of, and did so on a timer.
    ///
    /// The kubelet's image garbage collector calls this **by image ID**, which
    /// here is the digest. Removing only that key left every *name* still
    /// pointing at the rootfs, so `imageStatus` went on answering "present"
    /// while `createContainer` -- which the kubelet calls with the ID -- could
    /// no longer resolve it. The pod then failed with "image sha256:... has not
    /// been pulled" about an image that was sitting in the store with its ext4
    /// beside it, and `kubectl describe` said "already present on machine" two
    /// lines above the error.
    ///
    /// It also freed nothing. The ext4 is the only thing here that occupies
    /// disk, and it was left behind, so the collector saw no more space than
    /// before, ran again five minutes later, and broke the next image. On a
    /// full disk that is a loop that takes the node apart one image at a time,
    /// which is what "the wrong image keeps coming back" turned out to be.
    ///
    /// So removal is by identity: whatever the caller names, the whole record
    /// goes, and the disk is actually given back. And out of the store as
    /// well: the store is read back at startup, so an image left in it would
    /// return after a restart as though it had never been removed.
    func removeImage(_ reference: String) async {
        let direct = Set([reference, ImageReference.normalize(reference)])
        // The rootfs identifies the image; the names are aliases for it. If the
        // reference does not resolve to one, there is nothing to be coherent
        // about and the direct keys are all there is to drop.
        guard let mount = direct.compactMap({ rootfsCache[$0] }).first else {
            for key in direct {
                pulledImages.removeValue(forKey: key)
                rootfsCache.removeValue(forKey: key)
                imageConfigs.removeValue(forKey: key)
            }
            return
        }

        let aliases = rootfsCache.filter { $0.value.source == mount.source }.map(\.key)
        for key in Set(aliases).union(direct) {
            pulledImages.removeValue(forKey: key)
            rootfsCache.removeValue(forKey: key)
            imageConfigs.removeValue(forKey: key)
        }
        for key in Set(aliases).union(direct) where !key.hasPrefix("sha256:") {
            try? await store.delete(reference: key, performCleanup: false)
        }

        // Safe while a pod is running from it: the pod's VM attached the file
        // when it was made and holds it open, so removing the path does not
        // take the disk away from it.
        try? FileManager.default.removeItem(atPath: mount.source)
    }

    /// Stops every pod and releases every address. Without this the vmnet
    /// network outlives the process briefly, and the next ferry-cri to claim
    /// the same subnet fails with VMNET_FAILURE.
    func shutdown() async {
        for record in sandboxes.values {
            try? await record.pod.stop()
            releaseBlockVolumes(sandboxID: record.id)
            network.releaseInterface(record.id)
            try? FileManager.default.removeItem(atPath: scratchPath(record.id))
        }
        sandboxes.removeAll()
        containers.removeAll()
        // The pods are stopped, so nothing is using the network: end the
        // reservation now rather than leaving it to expire. This is what makes
        // `ferry down` followed by `ferry up` work at once instead of waiting
        // out a timer that asking would only have extended.
        network?.release()
    }

    func dnsAddress() -> String? {
        guard let dnsInterface else { return nil }
        return "\(dnsInterface.ipv4Address)".split(separator: "/").first.map(String.init)
    }

    func stateDirPath() -> String { config.stateDir.path() }

    func stateDirUsage() -> (capacity: UInt64, used: UInt64, inodes: UInt64) {
        var st = statfs()
        guard statfs(config.stateDir.path(), &st) == 0 else { return (0, 0, 0) }
        let block = UInt64(st.f_bsize)
        return (UInt64(st.f_blocks) * block, UInt64(st.f_blocks - st.f_bfree) * block, UInt64(st.f_files))
    }
}
