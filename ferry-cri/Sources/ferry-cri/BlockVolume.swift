// PersistentVolumes that are block devices rather than shares.
//
// Every kubelet mount reaches a pod as a virtiofs share of a host directory,
// and Virtualization.framework's virtiofs server runs as the Mac user. So the
// guest can read and write a share but never change who owns anything in it:
// chown fails with EPERM even as root. That breaks the most ordinary thing a
// chart does with a volume -- an init container that chowns the data directory
// to the uid the app runs as -- and postgres, which refuses a data directory
// that is not its own and 0700.
//
// ferry-storage therefore gives a single-writer claim (ReadWriteOnce or
// ReadWriteOncePod) a sparse disk image inside its directory. Here that image
// is attached to the pod's VM as a virtio-blk device and mounted as ext4 by the
// pod's own kernel, where ownership is real. Claims that allow many writers
// stay shares, and so does any volume made before this existed: without the
// image a volume directory is exactly what it always was.
//
// An ext4 filesystem can be mounted by one kernel at a time, and every pod is a
// kernel of its own, so an image is only ever attached to one VM -- see
// PodRuntime.claimBlockVolume. Within a VM it is attached once, as a pod-level
// volume, and each container that uses it gets a bind mount of it: two
// containers of one pod, or two subPaths of one claim, share one device rather
// than each mounting a device of their own onto the same file.

import Containerization
import ContainerizationEXT4
import Foundation
import SystemPackage

struct BlockVolume: Sendable, Equatable {
    /// The PersistentVolume's directory on the Mac, ferry-storage's
    /// `<root>/pvc-<uid>`. Also the pod volume's name, by its last component.
    let directory: String

    /// Unique within a pod, since one claim is attached to a pod at most once,
    /// and stable across rebuilds of the pod's LinuxPod.
    var name: String { (directory as NSString).lastPathComponent }
    var image: String { (directory as NSString).appendingPathComponent(Self.imageName) }

    /// Where LinuxPod mounts a pod-level volume inside the VM. It is the
    /// framework's private guestVolumePath, repeated here because a subPath has
    /// to be bound from beneath it and Mount.sharedMount can only name the
    /// volume's root.
    var guestPath: String { "/run/volumes/\(name)" }

    /// The name ferry-storage gives the image. Part of the contract between the
    /// two: ferry-storage creates it, this looks for it.
    static let imageName = "disk.ext4"

    var podVolume: LinuxPod.PodVolume {
        LinuxPod.PodVolume(name: name, source: .diskImage(path: URL(filePath: image)), format: "ext4")
    }

    /// The block volume a kubelet mount belongs to, and the subPath within it.
    ///
    /// A whole-volume mount hands over the PersistentVolume's own directory. A
    /// subPath mount hands over a directory beneath it -- ferry's kubelet
    /// resolves a subPath to a path inside the volume rather than bind-mounting
    /// it -- which on this kind of volume is an empty directory on the Mac that
    /// nothing reads: the subPath that matters is the one inside the
    /// filesystem. So walk up to the directory holding the image.
    ///
    /// Only a directory named the way ferry-storage names volumes counts, so a
    /// hostPath volume that happens to sit beside a file of the same name is
    /// never mistaken for one and attached as a disk.
    static func locate(hostPath: String) -> (volume: BlockVolume, subPath: String)? {
        var current = (hostPath as NSString).standardizingPath
        var below: [String] = []
        while current != "/" && !current.isEmpty {
            let name = (current as NSString).lastPathComponent
            if name.hasPrefix("pvc-") {
                var isDirectory: ObjCBool = false
                let image = (current as NSString).appendingPathComponent(imageName)
                if FileManager.default.fileExists(atPath: image, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    return (BlockVolume(directory: current), below.reversed().joined(separator: "/"))
                }
            }
            below.append(name)
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The smallest filesystem worth making, whatever the claim asked for. The
    /// journal alone needs 4 MiB, and the image is sparse, so rounding a tiny
    /// claim up costs nothing.
    static let minimumCapacity: UInt64 = 32 * 1024 * 1024

    /// Formats the image if it has never been formatted. Returns whether it did.
    ///
    /// ferry-storage leaves the image unformatted because there is no mkfs on a
    /// Mac; this uses the same ext4 writer the root filesystems are built with.
    /// A never-used image is recognisable twice over: no ext4 superblock magic
    /// (0xEF53 at byte 1080), and no blocks allocated to the sparse file at all.
    /// Both are required. An image that has data in it but no superblock is not
    /// something to "fix" by erasing it, so that is refused instead.
    ///
    /// The root directory is made 0777. The volume used to be a 0777 directory,
    /// and the kubelet does not apply fsGroup to hostPath volumes, so a
    /// non-root pod that wrote to its volume without an init container only
    /// worked because of that mode -- a root-owned 0755 filesystem would have
    /// quietly broken it. It is set here, once, and never again: a later mount
    /// leaves the root as the workload last left it, which is the point of
    /// being able to chown it.
    ///
    /// Journalled, because a pod VM can stop without unmounting -- ferry-cri
    /// dying takes its VMs with it -- and an unjournalled ext4 left dirty is
    /// mounted as it is, with no fsck in the guest to repair it.
    ///
    /// `subPaths` are made at the same mode, for the same reason: a subPath the
    /// first pod names is a directory it expects to write to.
    static func formatIfNeeded(image: String, subPaths: [String] = []) throws -> Bool {
        let fd = open(image, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw RuntimeFailure.invalid("cannot open volume image \(image): \(String(cString: strerror(errno)))")
        }
        var st = stat()
        var magic: [UInt8] = [0, 0]
        let statted = fstat(fd, &st) == 0
        let read = pread(fd, &magic, 2, 1080)
        close(fd)
        guard statted else {
            throw RuntimeFailure.invalid("cannot stat volume image \(image)")
        }
        if read == 2 && magic[0] == 0x53 && magic[1] == 0xEF { return false }
        guard st.st_blocks == 0 else {
            throw RuntimeFailure.invalid("""
                volume image \(image) holds data but no ext4 filesystem; \
                refusing to format over it
                """)
        }

        let capacity = max(UInt64(max(st.st_size, 0)), minimumCapacity)
        let formatter = try EXT4.Formatter(FilePath(image), minDiskSize: capacity, journal: .default)
        try formatter.create(path: FilePath("/"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o777))
        var made: Set<String> = ["/"]
        for subPath in subPaths {
            // Parents first, each at the same mode; the formatter does not make
            // intermediate directories on its own.
            var path = ""
            for component in subPath.split(separator: "/") where component != "." && component != ".." {
                path += "/\(component)"
                guard made.insert(path).inserted else { continue }
                try formatter.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFDIR, 0o777))
            }
        }
        try formatter.close()
        return true
    }
}
