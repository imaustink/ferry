// Writing directories into a pod VM, and reading them back out, through the
// guest agent's copy RPC.
//
// vminitd's mkdir ignores the mode it is asked for -- it calls
// FileManager.createDirectory with no attributes, under a 022 umask -- so a
// directory made through it is always 0755 root. Its copy RPC does better: a
// directory entry in the tar it extracts is fchmod'ed to the entry's mode after
// it is made, which is exactly what the kubelet does on Linux for a subPath
// (mkdirat, then fchmod to the volume root's mode, since mkdirat was subject to
// the umask). The same RPC, the other way, archives a directory, which is how a
// memory-backed emptyDir is carried from one pod VM to its replacement.
//
// Both resolve the path inside `root` the way the agent resolves a container's
// paths, with symlinks confined to it, so a link planted in a volume cannot send
// either of these anywhere else in the VM.

import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationOS
import Foundation

enum GuestFiles {
    /// Host vsock port for these transfers. LinuxPod allocates its own upward
    /// from 0x1000_0000, and ports are per VM, so one fixed port well away
    /// from that range is enough for transfers that run one at a time.
    static let port: UInt32 = 0x2F00_0001

    /// Makes `path` inside `root` a directory with exactly `mode`, if it is
    /// missing. Missing parents are made 0755, as the kubelet's are.
    ///
    /// Returns false if it was already there, which is left alone: it is the
    /// workload's, and its mode is whatever the workload last made it.
    static func makeDirectory(vm: any VirtualMachineInstance, root: String, path: String,
                              mode: mode_t) async throws -> Bool {
        let components = path.split(separator: "/").filter { $0 != "." && $0 != ".." }
        guard let last = components.last else { return false }
        let name = String(last)
        return try await withAgent(vm) { vminitd in
            do {
                _ = try await vminitd.stat(root: root, path: components.joined(separator: "/"))
                return false
            } catch let error as ContainerizationError where error.code == .notFound {}
            try await copyIn(vminitd, vm: vm, root: root,
                             path: components.dropLast().joined(separator: "/")) { fd in
                let writer = try ArchiveWriter(configuration: .init(format: .pax, filter: .gzip))
                try writer.open(fileDescriptor: fd)
                let entry = WriteEntry()
                entry.path = name
                entry.fileType = .directory
                entry.permissions = mode
                entry.owner = 0
                entry.group = 0
                entry.modificationDate = Date()
                try writer.writeEntry(entry: entry, data: nil)
                try writer.finishEncoding()
            }
            return true
        }
    }

    /// The mode of `root` itself, which a new subPath inherits.
    static func mode(vm: any VirtualMachineInstance, of root: String) async throws -> mode_t {
        try await withAgent(vm) { vminitd in
            mode_t(try await vminitd.stat(root: root, path: ".").mode) & 0o7777
        }
    }

    /// Everything under `root`, as the gzipped tar the agent sends. Held in
    /// memory rather than written to the Mac's disk: this is how a memory
    /// volume crosses to a new VM, and it should not touch a disk on the way.
    static func archive(vm: any VirtualMachineInstance, root: String) async throws -> Data {
        try await withAgent(vm) { vminitd in
            let listener = try vm.listen(port)
            defer { try? listener.finish() }
            return try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask {
                    try await vminitd.copy(direction: .copyOut, root: root, path: ".", vsockPort: port)
                    return nil
                }
                group.addTask {
                    guard let conn = await listener.first(where: { _ in true }) else {
                        throw RuntimeFailure.invalid("the guest never connected to send \(root)")
                    }
                    try listener.finish()
                    return try await Task.detached {
                        defer { conn.closeFile() }
                        return try conn.readToEnd() ?? Data()
                    }.value
                }
                var data = Data()
                for try await result in group { if let result { data = result } }
                return data
            }
        }
    }

    /// Extracts an archive from `archive(vm:root:)` into `root` in another VM.
    static func restore(vm: any VirtualMachineInstance, root: String, archive: Data) async throws {
        try await withAgent(vm) { vminitd in
            try await copyIn(vminitd, vm: vm, root: root, path: ".") { fd in
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: archive)
            }
        }
    }

    private static func withAgent<T: Sendable>(
        _ vm: any VirtualMachineInstance, _ body: (Vminitd) async throws -> T
    ) async throws -> T {
        let agent = try await vm.dialAgent()
        guard let vminitd = agent as? Vminitd else {
            try? await agent.close()
            throw RuntimeFailure.unsupported("the guest agent is not vminitd")
        }
        do {
            let result = try await body(vminitd)
            try? await agent.close()
            return result
        } catch {
            try? await agent.close()
            throw error
        }
    }

    /// Streams what `produce` writes to the descriptor it is given into the
    /// agent, which extracts it at `path` inside `root`.
    private static func copyIn(_ vminitd: Vminitd, vm: any VirtualMachineInstance,
                               root: String, path: String,
                               produce: @escaping @Sendable (Int32) throws -> Void) async throws {
        let listener = try vm.listen(port)
        defer { try? listener.finish() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await vminitd.copy(direction: .copyIn, root: root, path: path.isEmpty ? "." : path,
                                       vsockPort: port, isArchive: true)
            }
            group.addTask {
                guard let conn = await listener.first(where: { _ in true }) else {
                    throw RuntimeFailure.invalid("the guest never connected to receive \(root)/\(path)")
                }
                try listener.finish()
                try await Task.detached {
                    defer { conn.closeFile() }
                    try produce(conn.fileDescriptor)
                }.value
            }
            try await group.waitForAll()
        }
    }
}
