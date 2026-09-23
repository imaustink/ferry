// Read-ahead, per disk, in a pod's VM.
//
// Experiment 32 took virtio-blk's rotational flag out of ferry's kernel, which
// dropped every disk's read-ahead from 8 MiB to the kernel's 128 KiB. The
// memory that saved was on one disk, /dev/vda, the init filesystem: each page
// fault into vminitd and vmexec, 83 MiB static binaries, had read 8 MiB around
// itself. The throughput it cost was on the others. Experiment 36 (in
// experiments/32-pod-memory-footprint/FINDINGS.md) measured the two apart.
//
// So the kernel still boots every disk at 128 KiB, which is what vminitd runs
// with, and the pod's own disks -- its images, its scratch disk, its emptyDirs
// and block claims -- are raised here once the VM is up, before any of its
// containers runs. The init disk is never touched. Which device is which is
// not guessed: the framework records the letter it gave each pod volume.
//
// One connection to the guest agent and one sysfs write per disk, sent
// together, while the pod's containers are being added: no process in the
// guest. The dial shares the VM instance's lock with adding a container, so
// it does not hide entirely; a boot waits a median 3 ms more for it.

import Containerization
import Foundation

enum ReadAhead {
    /// What a pod asks for in place of the node's value, in KiB.
    static let annotation = "ferry.dev/read-ahead-kb"

    /// The kernel's own default, which every disk boots with.
    static let kernelDefaultKB = 128

    /// The node's value unless ferry-cri is told otherwise. Experiment 36: 1
    /// MiB takes a 64 KiB-block read of a large file from 4.8 to 14.4 GB/s
    /// (16.6 at 2 MiB, no better past it), and costs an alpine, nginx or
    /// python pod 0-4 MiB. It is the knee for a pod with one large binary,
    /// whose faults read around by the whole window: node costs 17 MiB more
    /// at 1 MiB, 24 at 2 MiB and 48 at 8 MiB.
    static let defaultKB = 1024

    /// Past this is a typo, not a tuning.
    static let maximumKB = 65536

    /// The value in KiB, or nil if it is not one.
    static func parse(_ value: String) -> Int? {
        guard let kb = Int(value.trimmingCharacters(in: .whitespaces)), (0...maximumKB).contains(kb) else { return nil }
        return kb
    }

    /// The read-ahead a pod's disks get: its annotation when that is a valid
    /// value, else the node's.
    static func kilobytes(annotations: [String: String], node: Int) -> Int {
        annotations[annotation].flatMap(parse) ?? node
    }

    /// The guest block devices the framework attached as the pod's own
    /// volumes, `vdb` and on: every disk but the init filesystem.
    static func podDevices(_ mounts: [String: [AttachedFilesystem]], podID: String) -> [String] {
        (mounts[podID] ?? []).compactMap { attached in
            attached.source.hasPrefix("/dev/vd") ? String(attached.source.dropFirst("/dev/".count)) : nil
        }
    }

    /// WriteFileFlags has public fields and no public initializer. All three
    /// off -- no O_CREAT, no O_APPEND, no parents -- is what a sysfs write
    /// wants, and three false Bools are three zero bytes. Nil if the struct
    /// ever stops being exactly that, rather than a crash.
    private static func noFlags() -> WriteFileFlags? {
        guard MemoryLayout<WriteFileFlags>.size == MemoryLayout<(Bool, Bool, Bool)>.size else { return nil }
        return unsafeBitCast((false, false, false), to: WriteFileFlags.self)
    }

    /// Sets each of the pod's disks to `kb` and returns the ones it set. Not
    /// fatal: a disk left at the kernel's default reads slower and works.
    static func apply(_ pod: LinuxPod, podID: String, kb: Int) async -> [String] {
        guard kb != kernelDefaultKB else { return [] }
        do {
            return try await pod.withVirtualMachineInstance { vm in
                let devices = podDevices(vm.mounts, podID: podID)
                guard !devices.isEmpty else { return [] }
                guard noFlags() != nil else { throw RuntimeFailure.unsupported("WriteFileFlags changed shape") }
                let agent = try await vm.dialAgent()
                guard let vminitd = agent as? Vminitd else {
                    try? await agent.close()
                    throw RuntimeFailure.unsupported("the guest agent is not vminitd")
                }
                let value = Data("\(kb)\n".utf8)
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for device in devices {
                            group.addTask {
                                try await vminitd.writeFile(path: "/sys/block/\(device)/queue/read_ahead_kb",
                                                            data: value, flags: noFlags()!, mode: 0)
                            }
                        }
                        try await group.waitForAll()
                    }
                } catch {
                    try? await agent.close()
                    throw error
                }
                try? await agent.close()
                return devices
            }
        } catch {
            FileHandle.standardError.write(
                "warning: \(podID)'s disks keep the kernel's read-ahead: \(error)\n".data(using: .utf8)!)
            return []
        }
    }
}
