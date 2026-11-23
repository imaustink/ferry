// Containers that join a pod whose VM is already running.
//
// Virtualization.framework cannot add a virtio device to a running machine,
// and a container used to be one: a writable clone of its image's ext4,
// attached as its own disk. So the containers of a pod were fixed at boot, and
// a container that crashed in a pod of two had nowhere to restart but a new
// VM -- the kubelet's restart is a new container, and a new container was a new
// disk.
//
// The fix is to stop making a container a device. Each distinct image a pod
// runs is attached once, read-only, as a pod volume; the pod gets one sparse
// scratch disk besides; and a container's root is an overlay of the two:
//
//     lowerdir = /run/volumes/ferry_image_<n>        the image, shared
//     upperdir = /run/volumes/ferry_scratch/<id>/upper
//     workdir  = /run/volumes/ferry_scratch/<id>/work
//
// None of that needs a new device, so a container can be added to the running
// machine at any time, as often as the kubelet likes, provided its image is one
// the pod already has. That is the ordinary case for a restart, a sidecar and
// every regular container after an init container of the same image.
//
// LinuxPod already knows how to add a container after create(): it asks the VM
// instance to hotplug the root filesystem and then mounts whatever comes back.
// VZVirtualMachineInstance has no provider for that and refuses. The provider
// below answers without touching the hypervisor: the "hotplug" is two mkdirs in
// the guest and an overlay description.
//
// Every container goes through this, including those present at boot, so
// there is one way a container gets a root filesystem rather than two.

import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Synchronization
import SystemPackage
@preconcurrency import Virtualization

/// Where a pod's images and scratch disk are in its VM.
struct PodRootfsLayout: Sendable {
    /// Image ext4 on the Mac -> the pod volume it is attached as.
    var images: [String: String] = [:]
    /// Pod volume name of the scratch disk, and its image on the Mac. Nil
    /// when the pod has none.
    var scratch: String?
    var scratchPath: String?
    /// Host directories every known container shares over virtiofs, put in the
    /// VM's share from the start so a boot-time container need not change it.
    var shares: [String: Bool] = [:]
    /// Where images that arrive after boot are put on the Mac, this pod's
    /// alone, and the guest helper that mounts them. Nil leaves a late image
    /// to cost the VM, as it always did. See PodRootfsProvider.attachLate.
    var lateDirectory: String?
    var loopHelper: String?

    /// Underscores cannot appear in a Kubernetes volume name, so these never
    /// collide with an emptyDir's pod volume, which is named after the volume.
    static let scratchVolume = "ferry_scratch"
    static func imageVolume(_ index: Int) -> String { "ferry_image_\(index)" }

    static func guestPath(_ volume: String) -> String { "/run/volumes/\(volume)" }

    func canRun(image: String) -> Bool { scratch != nil && images[image] != nil }

    /// Upper and work directories made in the scratch disk when it is
    /// formatted, one pair per container the VM is likely to see: `/<n>/upper`
    /// and `/<n>/work`, root-owned 0755 because an upper directory's root is
    /// the container's `/`.
    static let scratchSlots = 64

    /// Formats a sparse scratch filesystem at `path`, with its slots. Written
    /// with the same ext4 writer the images are, since a Mac has no mkfs.
    ///
    /// No journal. A journal is for a filesystem that must survive a machine
    /// stopping under it, and this one never outlives its machine: every VM
    /// boots on a fresh clone of the template. Without one there is no
    /// journal to load at mount and nothing written twice.
    static func formatScratch(at path: String, capacity: UInt64) throws {
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw RuntimeFailure.invalid("cannot create \(path): \(String(cString: strerror(errno)))")
        }
        let sized = ftruncate(fd, off_t(capacity)) == 0
        close(fd)
        guard sized else { throw RuntimeFailure.invalid("cannot size \(path): \(String(cString: strerror(errno)))") }
        let formatter = try EXT4.Formatter(FilePath(path), minDiskSize: capacity, journal: nil)
        let directory = EXT4.Inode.Mode(.S_IFDIR, 0o755)
        try formatter.create(path: FilePath("/"), mode: directory)
        try formatter.unlink(path: FilePath("/lost+found"))
        for slot in 0..<scratchSlots {
            try formatter.create(path: FilePath("/\(slot)"), mode: directory)
            try formatter.create(path: FilePath("/\(slot)/upper"), mode: directory)
            try formatter.create(path: FilePath("/\(slot)/work"), mode: directory)
        }
        try formatter.close()
    }

    /// The pod volumes this layout needs, images read-only.
    var podVolumes: [LinuxPod.PodVolume] {
        var volumes = images.sorted { $0.value < $1.value }.map { path, name in
            LinuxPod.PodVolume(name: name, source: .diskImage(path: URL(filePath: path), readOnly: true),
                               format: "ext4")
        }
        if let scratch, let path = scratchPath {
            volumes.append(LinuxPod.PodVolume(name: scratch, source: .diskImage(path: URL(filePath: path)),
                                              format: "ext4"))
        }
        return volumes
    }

    /// The host directory a virtiofs mount really shares: a file mount is its
    /// parent, which is what Containerization's FileMountContext attaches.
    static func sharedDirectory(for mount: Containerization.Mount) -> String? {
        guard case .virtiofs = mount.runtimeOptions else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mount.source, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return mount.source }
        return URL(fileURLWithPath: mount.source).resolvingSymlinksInPath().deletingLastPathComponent().path
    }
}

/// Things mounted into a running VM after boot, each under a name of its own
/// and each mounted once.
///
/// PodRuntime is an actor, and it re-enters at every await of an attach, so
/// two CreateContainer calls for one pod can overlap. The index that names an
/// attachment's file and mountpoint is taken from a counter that only grows,
/// so no two attempts share one -- not even a failed attempt and its retry,
/// whose mount may yet complete after its timeout. And callers attaching the
/// same key await the one attach in flight instead of starting a second.
final class LateAttachments: Sendable {
    private let next = Atomic<Int>(0)
    private let state = Mutex<(done: [String: String], inFlight: [String: Task<String, any Error>])>(([:], [:]))

    /// A fresh index, never handed out before.
    func reserveIndex() -> Int { next.wrappingAdd(1, ordering: .relaxed).oldValue }

    /// Where `key` is mounted, once its attach has finished.
    func mounted(_ key: String) -> String? { state.withLock { $0.done[key] } }

    var isEmpty: Bool { state.withLock { $0.done.isEmpty } }
    var mounts: [String] { state.withLock { Array($0.done.values) } }
    func removeAll() { state.withLock { $0.done.removeAll() } }

    /// Attaches `key` once: `body`, given a fresh index, mounts it and returns
    /// where. A caller that arrives while it runs awaits the same result; one
    /// that arrives after it failed tries again with a new index.
    @discardableResult
    func attach(_ key: String, _ body: @escaping @Sendable (Int) async throws -> String) async throws -> String {
        let found: (done: String?, task: Task<String, any Error>?) = state.withLock { state in
            if let done = state.done[key] { return (done, nil) }
            if let running = state.inFlight[key] { return (nil, running) }
            let index = reserveIndex()
            let task = Task<String, any Error> { try await body(index) }
            state.inFlight[key] = task
            return (nil, task)
        }
        if let done = found.done { return done }
        guard let task = found.task else { preconditionFailure("neither mounted nor attaching") }
        do {
            let mountpoint = try await task.value
            state.withLock { state in
                state.done[key] = mountpoint
                state.inFlight[key] = nil
            }
            return mountpoint
        } catch {
            state.withLock { state in
                if state.inFlight[key] == task { state.inFlight[key] = nil }
            }
            throw error
        }
    }
}

/// Installs the provider on the VM instance the pod makes, and seeds the
/// VM's virtiofs share with the directories already known.
struct PodRootfsExtension: VZInstanceExtension {
    let layout: PodRootfsLayout

    func configureVZ(_ config: inout VZVirtualMachineConfiguration,
                     allocator: any AddressAllocator<Character>,
                     storageDeviceCount: Int,
                     mountsByID: [String: [Containerization.Mount]]) throws {
        guard !layout.shares.isEmpty,
              let device = config.directorySharingDevices
                  .compactMap({ $0 as? VZVirtioFileSystemDeviceConfiguration })
                  .first(where: { $0.tag == "virtiofs" }) else { return }
        var directories = (device.share as? VZMultipleDirectoryShare)?.directories ?? [:]
        for (path, readOnly) in layout.shares {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let tag = try Containerization.Mount.share(source: path, destination: "/").tagHash
            if directories[tag] == nil {
                directories[tag] = VZSharedDirectory(url: URL(fileURLWithPath: path), readOnly: readOnly)
            }
        }
        device.share = VZMultipleDirectoryShare(directories: directories)
    }

    func didCreate(_ instance: VZVirtualMachineInstance) throws {
        instance.hotplugProvider = PodRootfsProvider(instance: instance, layout: layout)
    }
}

/// Gives a container added to a running pod its root filesystem, an overlay
/// of an attached image, and any virtiofs directory it needs that the VM does
/// not share yet.
final class PodRootfsProvider: HotplugProvider {
    // Unowned: the instance holds this provider, and nothing else does.
    private unowned let instance: VZVirtualMachineInstance
    private let layout: PodRootfsLayout
    /// The next of the scratch disk's ready-made upper directories. A fresh
    /// disk comes with every VM, so the count starts at zero with it.
    private let nextSlot = Atomic<Int>(0)
    /// The directory on the scratch disk holding each container's upper and
    /// work directories.
    private let uppers = Mutex<[String: String]>([:])
    /// Numbers discard's helper processes, whose ids must be unique.
    private let nextDiscard = Atomic<Int>(0)
    /// Images mounted after boot by attachLate: the image's disk on the Mac ->
    /// where it is mounted in the VM.
    private let late = LateAttachments()
    /// Block volumes mounted after boot by attachLateVolume: pod volume name ->
    /// where it is mounted in the VM.
    private let lateVolumes = LateAttachments()

    init(instance: VZVirtualMachineInstance, layout: PodRootfsLayout) {
        self.instance = instance
        self.layout = layout
    }

    func hotplug(_ rootfs: Containerization.Mount, id: String) async throws -> AttachedFilesystem {
        if id.hasPrefix(Self.podVolumePrefix) {
            return try await attachVolumeDevice(rootfs, name: String(id.dropFirst(Self.podVolumePrefix.count)))
        }
        guard let scratch = layout.scratch,
              let lower = layout.images[rootfs.source].map(PodRootfsLayout.guestPath)
                ?? late.mounted(rootfs.source) else {
            throw ContainerizationError(.unsupported, message: "image \(rootfs.source) is not attached to this pod")
        }
        // A slot made when the disk was formatted costs nothing here; past
        // them, two directories cost two round trips to the guest agent,
        // about 8ms, which at twenty containers was most of a boot's overhead.
        let slot = nextSlot.wrappingAdd(1, ordering: .relaxed).oldValue
        let base: String
        if slot < PodRootfsLayout.scratchSlots {
            base = "\(PodRootfsLayout.guestPath(scratch))/\(slot)"
        } else {
            base = "\(PodRootfsLayout.guestPath(scratch))/\(id)"
            let agent = try await instance.dialAgent()
            do {
                try await agent.mkdir(path: "\(base)/upper", all: true, perms: 0o755)
                try await agent.mkdir(path: "\(base)/work", all: true, perms: 0o755)
                try await agent.close()
            } catch {
                try? await agent.close()
                throw error
            }
        }
        uppers.withLock { $0[id] = base }
        return AttachedFilesystem(
            type: "overlay", source: "overlay", destination: rootfs.destination,
            options: ["lowerdir=\(lower)", "upperdir=\(base)/upper", "workdir=\(base)/work"])
    }

    /// Whether this VM can take a container of `image` without a new device.
    func has(image: String) -> Bool {
        layout.images[image] != nil || late.mounted(image) != nil
    }

    /// Mounts an image the VM was not booted with, so a container of it can
    /// join the running pod instead of costing the pod its VM.
    ///
    /// Virtualization.framework cannot add a disk to a running VM, but the
    /// VM's virtiofs share can grow (hotplugVirtioFS). So the image's disk is
    /// cloned -- free on APFS -- into this pod's late directory, the directory
    /// is shared, and ferry-loop, run as a root-of-VM process with
    /// CAP_SYS_ADMIN, puts a read-only loop device under it and mounts it in
    /// PID 1's mount namespace, where container roots are assembled. Reads run
    /// at 2.6-4.2 GB/s against 3.2-12 for a disk attached at boot
    /// (experiments/42-late-disks), which an image's start-up does not notice.
    ///
    /// The loop device is autoclear and goes with the VM; the directory on
    /// the Mac goes with the sandbox (removeLateDirectory).
    func attachLate(image: String) async throws {
        guard layout.images[image] == nil else { return }
        guard let directory = layout.lateDirectory, layout.loopHelper != nil else {
            throw ContainerizationError(.unsupported, message: "late images are off for this pod")
        }
        try await late.attach(image) { [self] index in
            let fm = FileManager.default
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let file = "late-\(index).ext4"
            let hostFile = (directory as NSString).appendingPathComponent(file)
            try? fm.removeItem(atPath: hostFile)
            try fm.copyItem(atPath: image, toPath: hostFile)   // clonefile on APFS
            let shared = try await shareReadOnly()
            let mountpoint = PodRootfsLayout.guestPath("ferry_late_\(index)")
            try await runHelper([shared.helper, "\(shared.directory)/\(file)", mountpoint, "ro"],
                                id: "ferry-late-\(index)")
            return mountpoint
        }
    }

    /// Puts ferry-loop in this pod's late directory and shares the directory
    /// read-only, returning where both are in the VM. The helper runs as VM
    /// root with CAP_SYS_ADMIN, so it is only ever run from this share, which
    /// nothing in the guest can write -- never from the read-write one.
    private func shareReadOnly() async throws -> (directory: String, helper: String) {
        guard let directory = layout.lateDirectory, let helper = layout.loopHelper else {
            throw ContainerizationError(.unsupported, message: "late mounts are off for this pod")
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let hostHelper = (directory as NSString).appendingPathComponent("ferry-loop")
        if !fm.fileExists(atPath: hostHelper) {
            // Copied beside and renamed into place, so a concurrent attach
            // never sees half a binary.
            let partial = hostHelper + ".\(UUID().uuidString)"
            try fm.copyItem(atPath: helper, toPath: partial)
            if rename(partial, hostHelper) != 0 {
                let reason = String(cString: strerror(errno))
                try? fm.removeItem(atPath: partial)
                throw RuntimeFailure.invalid("cannot place \(hostHelper): \(reason)")
            }
        }
        let share = Containerization.Mount.share(source: directory, destination: "/", options: ["ro"])
        try await hotplugVirtioFS([share], id: "late")
        let guestDirectory = "/run/virtiofs/\(try share.tagHash)"
        return (guestDirectory, "\(guestDirectory)/ferry-loop")
    }

    /// The hotplug id LinuxPod.attachVolume gives a disk-image volume.
    static let podVolumePrefix = "pod-volume-"
    /// Loop devices for late volumes are /dev/loop<base + index>: numbered by
    /// ferry-cri, so it knows the device without reading the helper's
    /// output, and far above the low numbers LOOP_CTL_GET_FREE hands late
    /// images.
    static let volumeDeviceBase = 512
    /// The index attachVolume reserved for each volume being attached, read
    /// back by the hotplug call LinuxPod makes in the middle of it.
    private let volumeIndex = Mutex<[String: Int]>([:])

    /// Mounts a volume the VM was not booted with, through LinuxPod's own
    /// attachVolume (Containerization #1022), so LinuxPod mounts it where a
    /// boot volume goes (/run/volumes/<name>), accepts containers' shared
    /// mounts of it, and unmounts it when the pod stops -- after its
    /// containers, which writes back what they did not sync. Without that
    /// unmount, unsynced writes were lost: a VM stopped 650 ms after 4 MiB
    /// was written left a volume with no such file (experiments/42-late-disks).
    ///
    /// A memory volume is a tmpfs, which attachVolume mounts itself. A
    /// disk-image volume comes back here as a hotplug; see attachVolumeDevice.
    /// Concurrent calls for one volume share one attach.
    func attachVolume(_ volume: LinuxPod.PodVolume, to pod: LinuxPod) async throws {
        try await lateVolumes.attach(volume.name) { [self] index in
            volumeIndex.withLock { $0[volume.name] = index }
            defer { volumeIndex.withLock { _ = $0.removeValue(forKey: volume.name) } }
            try await pod.attachVolume(volume)
            return "/run/volumes/\(volume.name)"
        }
    }

    /// The device under a late disk-image volume, which LinuxPod then mounts.
    ///
    /// The volume is written to, so it cannot be a clone. Its own file is hard
    /// linked into rw/ under the late directory, which is shared read-write;
    /// sharing the volume's real directory instead would show the pod every
    /// other volume beside it. ferry-loop, from the read-only share, puts it
    /// under a loop device. A flush in the guest arrives as a host fsync(),
    /// which is what a volume disk attached at boot gets
    /// (VZDiskImageSynchronizationMode.fsync), and nothing synced is lost when
    /// the VM is killed. Synced writes cost about twice as much until a
    /// rebuild attaches the volume as a disk.
    private func attachVolumeDevice(_ mount: Containerization.Mount, name: String) async throws -> AttachedFilesystem {
        guard let base = layout.lateDirectory, layout.loopHelper != nil,
              let index = volumeIndex.withLock({ $0[name] }) else {
            throw ContainerizationError(.unsupported, message: "late volumes are off for this pod")
        }
        let fm = FileManager.default
        let directory = (base as NSString).appendingPathComponent("rw")
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let file = "\(name).ext4"
        let hostFile = (directory as NSString).appendingPathComponent(file)
        try? fm.removeItem(atPath: hostFile)
        // A hard link, not a copy: the guest writes the volume itself. Fails
        // across file systems, and the caller falls back to a rebuild.
        try fm.linkItem(atPath: mount.source, toPath: hostFile)
        // The helper comes from the read-only share; only the volume's file
        // is in this one, which the guest can write.
        let shared = try await shareReadOnly()
        let share = Containerization.Mount.share(source: directory, destination: "/", options: [])
        try await hotplugVirtioFS([share], id: "late-rw")
        let readOnly = mount.options.contains("ro")
        let device = Self.volumeDeviceBase + index
        try await runHelper([shared.helper, "attach", "/run/virtiofs/\(try share.tagHash)/\(file)",
                             readOnly ? "ro" : "rw", "\(device)"], id: "ferry-late-vol-\(index)")
        return AttachedFilesystem(type: mount.type, source: "/dev/loop\(device)",
                                  destination: mount.destination, options: mount.options)
    }

    /// Runs ferry-loop as a root-of-VM process with CAP_SYS_ADMIN: in the VM's
    /// own root and PID 1's mount namespace, where container roots are put
    /// together, and not in any container's.
    private func runHelper(_ args: [String], id: String) async throws {
        var process = ContainerizationOCI.Process(
            args: args,
            env: ["PATH=/usr/bin:/bin"],
            capabilities: Containerization.LinuxCapabilities(capabilities: [.sysAdmin]).toOCI())
        process.user = ContainerizationOCI.User(uid: 0, gid: 0)
        let agent = try await instance.dialAgent()
        do {
            // containerID nil: a process in the VM's own root and namespaces,
            // not in any container's (Containerization 0.51, #1020).
            try await agent.createProcess(id: id, containerID: nil, stdinPort: nil, stdoutPort: nil,
                                          stderrPort: nil, ociRuntimePath: nil,
                                          configuration: ContainerizationOCI.Spec(process: process), options: nil)
            _ = try await agent.startProcess(id: id, containerID: nil)
            let status = try await agent.waitProcess(id: id, containerID: nil, timeoutInSeconds: 30)
            try? await agent.deleteProcess(id: id, containerID: nil)
            try? await agent.close()
            guard status.exitCode == 0 else {
                throw ContainerizationError(.internalError, message: "ferry-loop exited \(status.exitCode): \(args.dropFirst().joined(separator: " "))")
            }
        } catch {
            try? await agent.deleteProcess(id: id, containerID: nil)
            try? await agent.close()
            throw error
        }
    }

    func registerMounts(id: String, rootfs: AttachedFilesystem, additionalMounts: [Containerization.Mount]) throws {
        // No device is allocated for anything here: the additional mounts of a
        // ferry container are shares, pod-volume binds and guest binds.
        let attached = try [rootfs] + additionalMounts.map {
            try AttachedFilesystem(mount: $0, allocator: NoDevices())
        }
        instance.withMountRegistry { $0[id] = attached }
    }

    /// The overlay was unmounted by the caller. What it wrote stays on the
    /// scratch disk until the container is removed -- see discard -- or goes
    /// with the disk when the pod does.
    func releaseHotplug(id: String) async throws {
        instance.withMountRegistry { _ = $0.removeValue(forKey: id) }
    }

    /// Deletes what a container wrote to its root, once the kubelet has
    /// removed the container for good.
    ///
    /// Every attempt of a crash-looping container has an upper directory of
    /// its own, and without this each one stayed on the scratch disk until the
    /// pod was deleted: one that writes 100 MiB before it dies filled 16 GiB in
    /// a day of backoff, and then every container in the pod was out of space.
    ///
    /// The guest agent can make a directory but not remove one, so ferry-loop
    /// does, as a root-of-VM process (Containerization #1020) run from the
    /// read-only late share. This used to run `rm` in a short-lived container
    /// of the image the container ran, so a distroless or scratch image, with
    /// no `rm`, kept every crash-looping attempt's writes until the pod went.
    func discard(id: String) async {
        guard let base = uppers.withLock({ $0.removeValue(forKey: id) }) else { return }
        do {
            let shared = try await shareReadOnly()
            try await runHelper([shared.helper, "rm", base], id: "ferry-rm-\(nextDiscard.wrappingAdd(1, ordering: .relaxed).oldValue)")
        } catch {
            FileHandle.standardError.write(
                "warning: what \(id) wrote stays on its pod's scratch disk: \(error)\n".data(using: .utf8)!)
        }
    }

    /// Adds any directory the VM does not already share to its one virtiofs
    /// device. Its share can be replaced while the machine runs, and the guest
    /// sees each directory as /run/virtiofs/<tag>, so adding one is a new share
    /// with one more entry.
    func hotplugVirtioFS(_ mounts: [Containerization.Mount], id: String) async throws {
        var wanted: [String: (path: String, readOnly: Bool)] = [:]
        for mount in mounts {
            guard case .virtiofs = mount.runtimeOptions else { continue }
            wanted[try mount.tagHash] = (mount.source, mount.options.contains("ro"))
        }
        guard !wanted.isEmpty else { return }
        let request = wanted
        let instance = self.instance
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            instance.vmQueue.async {
                guard let device = instance.vzVirtualMachine.directorySharingDevices
                    .compactMap({ $0 as? VZVirtioFileSystemDevice })
                    .first(where: { $0.tag == "virtiofs" }) else {
                    done.resume(throwing: ContainerizationError(.notFound, message: "pod VM has no virtiofs device"))
                    return
                }
                var directories = (device.share as? VZMultipleDirectoryShare)?.directories ?? [:]
                var added = false
                for (tag, share) in request where directories[tag] == nil {
                    directories[tag] = VZSharedDirectory(url: URL(fileURLWithPath: share.path), readOnly: share.readOnly)
                    added = true
                }
                if added { device.share = VZMultipleDirectoryShare(directories: directories) }
                done.resume()
            }
        }
    }

    /// Left shared. Another container may use the same directory, and a
    /// directory the pod no longer mounts is still only this pod's own.
    func releaseVirtioFS(id: String) async throws {}
}

/// The allocator AttachedFilesystem asks for a block mount's device letter.
/// A container added to a running VM cannot have a device of its own.
private struct NoDevices: AddressAllocator {
    func allocate() throws -> Character {
        throw ContainerizationError(.unsupported, message: "a block device cannot be added to a running pod")
    }
    func reserve(_ address: Character) throws {}
    func release(_ address: Character) throws {}
    func disableAllocator() -> Bool { false }
}
