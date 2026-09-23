// A PersistentVolume's disk image, made ready to attach to a running machine.
//
// A machine's devices are fixed when it boots, so a claim used to reach one as
// a directory in the virtiofs volumes share -- where chown fails, because
// virtiofs is served as the Mac user. Experiment 26 found the one device
// Virtualization.framework will add to a live VM: USB mass storage. So a claim
// of the ferry-local-block class is an ext4 image, and when a pod using it is
// scheduled onto a machine, ferry-machined lists the image in that machine's
// .usb file and this attaches it. The filesystem is the machine kernel's own,
// and ownership inside it is real.
//
// Three things have to be true before it goes onto the bus, and this makes them
// so:
//
// - It is formatted. ferry-storage cannot format it, having no mkfs on a Mac,
//   so the first attach does, with the same ext4 writer and the same rules
//   ferry-cri uses for a volume on the Mac's node (BlockVolume.formatIfNeeded):
//   only a never-written sparse file is formatted, the root is 0777, and it is
//   journalled so a machine that dies holding it leaves it recoverable.
// - It can be found. USB gives the guest nothing to tell two disks apart by --
//   every one is an `Apple Virtual Disk` with no serial -- so the filesystem is
//   labelled with the claim, and the machine's volume driver looks the disk up
//   by label. The label is written into the primary superblock alone; nothing
//   in this ext4 is checksummed (the formatter sets no metadata_csum), so that
//   is a sixteen-byte write and not a rewrite.
// - Nobody else has it. One ext4 can be mounted by one kernel, so the volume's
//   directory is locked with flock for as long as the disk is attached -- the
//   same lock ferry-cri takes before attaching a claim to a pod VM, so a claim
//   can never be on a machine and on a pod VM on the Mac at once.

import ContainerizationEXT4
import Foundation
import SystemPackage

enum VolumeDisk {
    /// The ext4 volume label a claim's disk carries: the claim's UID, taken
    /// from its directory `<volumes>/pvc-<uid>`, without dashes and cut to the
    /// sixteen bytes a label holds. ferry-storage writes the same value into
    /// the PersistentVolume, which is how the machine side knows what to look for.
    static func label(forImage image: String) -> String? {
        let directory = ((image as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard directory.hasPrefix("pvc-") else { return nil }
        let uid = directory.dropFirst(4).replacingOccurrences(of: "-", with: "")
        guard uid.count >= 16 else { return nil }
        return String(uid.prefix(16))
    }

    static let minimumCapacity: UInt64 = 32 * 1024 * 1024
    static let labelOffset: off_t = 1024 + 0x78

    enum Failure: Error, CustomStringConvertible {
        case refused(String)
        var description: String { switch self { case .refused(let m): m } }
    }

    /// Makes the image ready and returns the held lock, which the caller closes
    /// when the disk has been detached.
    static func prepare(image: String) throws -> Int32 {
        guard let label = label(forImage: image) else {
            throw Failure.refused("\(image) is not a volume's disk image")
        }
        let directory = (image as NSString).deletingLastPathComponent
        let lock = open(directory, O_RDONLY | O_CLOEXEC)
        guard lock >= 0 else {
            throw Failure.refused("cannot open \(directory): \(String(cString: strerror(errno)))")
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            // Usually a moment: the machine it is leaving has not finished
            // detaching it. Otherwise a pod VM on the Mac's own node has it.
            throw Failure.refused("\(directory) is still held -- by the machine it is leaving, or a pod VM on the Mac")
        }
        do {
            if try formatIfNeeded(image: image) { print("    usb: formatted \(image)") }
            try setLabel(label, image: image)
        } catch {
            close(lock)
            throw error
        }
        return lock
    }

    static func formatIfNeeded(image: String) throws -> Bool {
        let fd = open(image, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw Failure.refused("cannot open \(image): \(String(cString: strerror(errno)))")
        }
        var st = stat()
        var magic: [UInt8] = [0, 0]
        let statted = fstat(fd, &st) == 0
        let read = pread(fd, &magic, 2, 1080)
        close(fd)
        guard statted else { throw Failure.refused("cannot stat \(image)") }
        if read == 2 && magic[0] == 0x53 && magic[1] == 0xEF { return false }
        guard st.st_blocks == 0 else {
            throw Failure.refused("\(image) holds data but no ext4 filesystem; refusing to format over it")
        }
        let size = max(UInt64(max(st.st_size, 0)), minimumCapacity)
        let formatter = try EXT4.Formatter(FilePath(image), minDiskSize: size, journal: .default)
        try formatter.create(path: FilePath("/"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o777))
        try formatter.close()
        return true
    }

    static func setLabel(_ label: String, image: String) throws {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in label.utf8.prefix(16).enumerated() { bytes[i] = b }
        let fd = open(image, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else {
            throw Failure.refused("cannot open \(image): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var current = [UInt8](repeating: 0, count: 16)
        if pread(fd, &current, 16, labelOffset) == 16 && current == bytes { return }
        guard pwrite(fd, bytes, 16, labelOffset) == 16, fsync(fd) == 0 else {
            throw Failure.refused("cannot label \(image): \(String(cString: strerror(errno)))")
        }
    }
}
