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
    static func formatScratch(at path: String, capacity: UInt64, journalBytes: UInt64) throws {
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw RuntimeFailure.invalid("cannot create \(path): \(String(cString: strerror(errno)))")
        }
        let sized = ftruncate(fd, off_t(capacity)) == 0
        close(fd)
        guard sized else { throw RuntimeFailure.invalid("cannot size \(path): \(String(cString: strerror(errno)))") }
        let formatter = try EXT4.Formatter(FilePath(path), minDiskSize: capacity,
                                           journal: EXT4.JournalConfig(size: journalBytes))
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
    /// Each container's upper directory, and the image beneath it.
    private let uppers = Mutex<[String: (base: String, lower: String)]>([:])

    init(instance: VZVirtualMachineInstance, layout: PodRootfsLayout) {
        self.instance = instance
        self.layout = layout
    }

    func hotplug(_ rootfs: Containerization.Mount, id: String) async throws -> AttachedFilesystem {
        guard let image = layout.images[rootfs.source], let scratch = layout.scratch else {
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
        uppers.withLock { $0[id] = (base, PodRootfsLayout.guestPath(image)) }
        return AttachedFilesystem(
            type: "overlay", source: "overlay", destination: rootfs.destination,
            options: ["lowerdir=\(PodRootfsLayout.guestPath(image))",
                      "upperdir=\(base)/upper", "workdir=\(base)/work"])
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
    /// The guest agent can make a directory but not remove one, so this runs
    /// `rm` in a short-lived container of the image the container ran -- which
    /// has an `rm` far more often than not -- with the upper directory bound
    /// at /tmp. Its root is that image under a tmpfs overlay, since vmexec
    /// has to make /proc and /dev in whatever root it is given, and the tmpfs
    /// goes when it is done. An image without an `rm` keeps its garbage, as
    /// before, and says so.
    func discard(id: String) async {
        guard let (base, lower) = uppers.withLock({ $0.removeValue(forKey: id) }) else { return }
        let janitor = "rm-\(id)"
        let work = "/run/ferry-rm/\(id)"
        var process = ContainerizationOCI.Process(
            args: ["/bin/rm", "-rf", "/tmp/upper", "/tmp/work"],
            env: ["PATH=/usr/sbin:/usr/bin:/sbin:/bin"],
            capabilities: Containerization.LinuxCapabilities.allCapabilities.toOCI())
        process.user = ContainerizationOCI.User(uid: 0, gid: 0)
        let spec = ContainerizationOCI.Spec(
            process: process,
            mounts: [ContainerizationOCI.Mount(type: "proc", source: "proc", destination: "/proc", options: []),
                     ContainerizationOCI.Mount(type: "devtmpfs", source: "none", destination: "/dev",
                                               options: ["nosuid", "mode=755"]),
                     ContainerizationOCI.Mount(type: "none", source: base, destination: "/tmp", options: ["bind"])],
            root: ContainerizationOCI.Root(path: "\(work)/root", readonly: false),
            linux: ContainerizationOCI.Linux(
                cgroupsPath: "/container/ferry-rm/\(id)",
                namespaces: [.init(type: .mount), .init(type: .pid), .init(type: .ipc), .init(type: .uts)]))
        var agent: Vminitd?
        do {
            let dialed = try await instance.dialAgent()
            agent = dialed
            try await dialed.mount(ContainerizationOCI.Mount(type: "tmpfs", source: "tmpfs", destination: work,
                                                              options: ["size=16m"]))
            try await dialed.mkdir(path: "\(work)/upper", all: true, perms: 0o755)
            try await dialed.mkdir(path: "\(work)/work", all: true, perms: 0o755)
            try await dialed.mount(ContainerizationOCI.Mount(
                type: "overlay", source: "overlay", destination: "\(work)/root",
                options: ["lowerdir=\(lower)", "upperdir=\(work)/upper", "workdir=\(work)/work"]))
            try await dialed.createProcess(id: janitor, containerID: janitor, stdinPort: nil, stdoutPort: nil,
                                           stderrPort: nil, ociRuntimePath: nil, configuration: spec, options: nil)
            _ = try await dialed.startProcess(id: janitor, containerID: janitor)
            let status = try await dialed.waitProcess(id: janitor, containerID: janitor, timeoutInSeconds: 60)
            if status.exitCode != 0 { throw ContainerizationError(.internalError, message: "rm exited \(status.exitCode)") }
        } catch {
            FileHandle.standardError.write(
                "warning: what \(id) wrote stays on its pod's scratch disk: \(error)\n".data(using: .utf8)!)
        }
        guard let agent else { return }
        try? await agent.deleteProcess(id: janitor, containerID: janitor)
        try? await agent.umount(path: "\(work)/root", flags: 0)
        try? await agent.umount(path: work, flags: 0)
        try? await agent.close()
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
