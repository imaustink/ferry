// Can a disk image that arrives after a pod VM has booted be loop-mounted in
// the VM's root, where containers are built, by a root-of-VM process?
//
//   late-disks list                      images in ferry-cri's store, with disks
//   late-disks run <shell-image> <big-image>
//
// <shell-image> supplies a static busybox (busybox:latest does) and is the
// pod's one container. <big-image>'s disk is attached once at boot and once
// late, through a virtiofs share, so reads can be compared on the same bytes.
//
// Reads ferry-cri's state directory (image disks, the unpacked guest agent)
// and copies what it uses with clonefile; it changes nothing there.

import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import ContainerizationOS
import Foundation
import NIOPosix
import SystemPackage

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let state = URL(filePath: ProcessInfo.processInfo.environment["FERRY_CRI_STATE"] ?? "/tmp/ferry-run/cri")
let kernelPath = ProcessInfo.processInfo.environment["FERRY_KERNEL"]
    ?? "\(FileManager.default.currentDirectoryPath)/../../kernel/vmlinux-arm64"
let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")
let work = URL(filePath: ProcessInfo.processInfo.environment["WORK"] ?? NSTemporaryDirectory())
    .appending(component: "late-disks")

func disk(for reference: String, in store: ImageStore) async throws -> URL {
    let image = try await store.get(reference: reference)
    let digest = try await image.descriptor(for: platform).digest
    let safe = digest.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
    return state.appending(component: "image-\(safe).ext4")
}

func clone(_ from: URL, to: URL) throws {
    try? FileManager.default.removeItem(at: to)
    try FileManager.default.copyItem(at: from, to: to)   // clonefile on APFS
}

let store = try ImageStore(path: state)

if args.count > 1 && args[1] == "list" {
    for image in try await store.list() {
        guard let path = try? await disk(for: image.reference, in: store) else { continue }
        let exists = FileManager.default.fileExists(atPath: path.path())
        print("\(exists ? "disk" : "    ")  \(image.reference)")
    }
    exit(0)
}

guard args.count == 4, args[1] == "run" else {
    print("usage: late-disks list | late-disks run <shell-image> <big-image>"); exit(2)
}

let shellDisk = try await disk(for: args[2], in: store)
let bigDisk = try await disk(for: args[3], in: store)
guard let initfsName = try FileManager.default.contentsOfDirectory(atPath: state.path())
    .first(where: { $0.hasPrefix("init-") && $0.hasSuffix(".ext4") }) else {
    print("no init-*.ext4 in \(state.path()); start ferry-cri from this branch once"); exit(1)
}

try? FileManager.default.removeItem(at: work)
let share = work.appending(component: "share")
try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
let shellCopy = work.appending(component: "shell.ext4")
let bootCopy = work.appending(component: "big-boot.ext4")
let bootVolume = work.appending(component: "vol-boot.ext4")
try clone(shellDisk, to: shellCopy)
try clone(bigDisk, to: bootCopy)

/// A sparse, journalled ext4, as ferry-cri makes a PersistentVolume.
func formatVolume(_ url: URL, bytes: UInt64) throws {
    FileManager.default.createFile(atPath: url.path(), contents: nil)
    let fd = open(url.path(), O_RDWR)
    ftruncate(fd, off_t(bytes)); close(fd)
    let formatter = try EXT4.Formatter(FilePath(url.path()), minDiskSize: bytes, journal: .default)
    try formatter.create(path: FilePath("/"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o777))
    try formatter.close()
}
try formatVolume(bootVolume, bytes: 512 << 20)

let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
var commandLine = Kernel.CommandLine(debug: false, panic: 0)
commandLine.kernelArgs += ["swiotlb=noforce", "transparent_hugepage=never"]
let kernel = Kernel(path: URL(filePath: kernelPath), platform: .linuxArm, commandline: commandLine)
let initfs = Mount.block(format: "ext4", source: state.appending(component: initfsName).path(),
                         destination: "/", options: ["ro"])

let pod = try LinuxPod("late-disks", vmm: VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs, group: group),
                       vm: VMResources(cpus: 2, memoryInBytes: 1 << 30)) { c in
    c.volumes = [
        .init(name: "bootimg", source: .diskImage(path: bootCopy, readOnly: true), format: "ext4"),
        .init(name: "bootvol", source: .diskImage(path: bootVolume, readOnly: false), format: "ext4"),
        // Empty at boot: everything late arrives through here.
        .init(name: "late", source: .virtiofs(path: share, readOnly: false), format: "virtiofs"),
    ]
}
try await pod.addContainer("sleeper", rootfs: .block(format: "ext4", source: shellCopy.path(), destination: "/", options: [])) { c in
    c.process.arguments = ["/bin/sleep", "3600"]
}
try await pod.create()
try await pod.startContainer("sleeper")
print("booted; late share empty: \(try FileManager.default.contentsOfDirectory(atPath: share.path()).isEmpty)")

let agent = try await Vminitd(connection: try await pod.dialVsock(port: Vminitd.port), group: group)
let rootfs = "/run/container/sleeper/rootfs"
// busybox:latest is dynamically linked, and the VM root has no loader of its
// own (the initfs is vminitd alone), so it runs through the image's loader.
nonisolated(unsafe) var busyboxArgs = ["\(rootfs)/bin/busybox"]
for loader in ["lib/ld-musl-aarch64.so.1", "lib/ld-linux-aarch64.so.1", "lib64/ld-linux-aarch64.so.1"] {
    if (try? await agent.stat(root: "/", path: "\(rootfs)/\(loader)")) != nil {
        busyboxArgs = ["\(rootfs)/\(loader)", "--library-path", "\(rootfs)/lib", "\(rootfs)/bin/busybox"]
        print("   busybox runs through \(loader)")
        break
    }
}
let busybox = busyboxArgs.joined(separator: " ")
// One output file per step, never deleted from the Mac while the guest may
// still have it cached: virtiofs keeps the old name, and the next redirect
// to it fails before the script prints anything.

/// Runs a busybox sh script as a root-of-VM process; its output goes to a file
/// in the late share, which the Mac reads back. Returns the exit code.
nonisolated(unsafe) var serial = 0
func root(_ script: String, sysAdmin: Bool = true, extra: [CapabilityName] = []) async throws -> Int32 {
    serial += 1
    let id = "root-\(serial)"
    var process = ContainerizationOCI.Process(
        args: busyboxArgs + ["sh", "-c", "B='\(busybox)'; exec >/run/volumes/late/out-\(serial).txt 2>&1; \(script)"],
        env: ["PATH=/usr/bin:/bin"])
    if sysAdmin { process.capabilities = LinuxCapabilities(capabilities: [.sysAdmin] + extra).toOCI() }
    try await agent.createProcess(id: id, containerID: nil, stdinPort: nil, stdoutPort: nil, stderrPort: nil,
                                  ociRuntimePath: nil, configuration: ContainerizationOCI.Spec(process: process),
                                  options: nil)
    _ = try await agent.startProcess(id: id, containerID: nil)
    let status = try await agent.waitProcess(id: id, containerID: nil)
    try await agent.deleteProcess(id: id, containerID: nil)
    return status.exitCode
}
func output() -> String { (try? String(contentsOf: share.appending(component: "out-\(serial).txt"), encoding: .utf8)) ?? "" }
func say(_ title: String, _ code: Int32) {
    print("\n== \(title) (exit \(code))")
    print(output().split(separator: "\n").map { "   " + $0 }.joined(separator: "\n"))
}

// 0. ferry-cri's own helper, bin/ferry-loop, on the same kind of late disk.
if let helper = ProcessInfo.processInfo.environment["FERRY_LOOP"] {
    try clone(URL(filePath: helper), to: share.appending(component: "ferry-loop"))
    try clone(bigDisk, to: share.appending(component: "helper-late.ext4"))
    let code = try await root("""
        /run/volumes/late/ferry-loop /run/volumes/late/helper-late.ext4 /run/volumes/helper-img ro; echo "exit $?"
        $B ls /run/volumes/helper-img | $B head -3
        """)
    say("bin/ferry-loop", code)
    if ProcessInfo.processInfo.environment["HELPER_ONLY"] == "1" { try await pod.stop(); exit(0) }
}

// 1. A disk that arrives after boot, loop-mounted read-only in the VM root.
let t0 = Date()
try clone(bigDisk, to: share.appending(component: "big-late.ext4"))
let cloned = Date().timeIntervalSince(t0)
var code = try await root("""
    d=$($B losetup -f) && $B losetup -r $d /run/volumes/late/big-late.ext4 || exit 10
    echo "loop device: $d"
    $B mkdir -p /run/volumes/late-img && $B mount -t ext4 -o ro $d /run/volumes/late-img || exit 11
    echo "mounted: $($B grep late-img /proc/self/mounts)"
    echo "top level: $($B ls /run/volumes/late-img | $B head -8 | $B tr '\\n' ' ')"
    """)
say("late disk, read-only loop mount (host clone took \(String(format: "%.1f", cloned * 1000)) ms)", code)

// Visible where vminitd, and so container setup, looks.
let lateStat = try? await agent.stat(root: "/", path: "/run/volumes/late-img")
let bootStat = try? await agent.stat(root: "/", path: "/run/volumes")
print("   vminitd sees it as its own mount: \(lateStat.map { $0.dev != bootStat?.dev } ?? false)")

// 2. Cold reads of the same file, from the boot-attached disk and the late one.
code = try await root("""
    f=$($B find /run/volumes/bootimg -xdev -type f -size +20000k 2>/dev/null | $B head -1)
    [ -n "$f" ] || f=$($B find /run/volumes/bootimg -xdev -type f -size +2000k | $B head -1)
    rel=${f#/run/volumes/bootimg}
    echo "file: $rel ($($B stat -c %s "$f") bytes)"
    for src in bootimg late-img; do
      for i in 1 2 3; do
        $B sync; echo 3 > /proc/sys/vm/drop_caches
        echo -n "$src cold read $i: "; $B dd if=/run/volumes/$src$rel of=/dev/null bs=1M 2>&1 | $B tail -1
      done
    done
    """)
say("cold reads, boot-attached virtio disk vs late loop disk over virtiofs", code)

// 3. A writable late disk: synced small writes, and whether they reach the Mac.
let lateVolume = share.appending(component: "vol-late.ext4")
try formatVolume(lateVolume, bytes: 512 << 20)
code = try await root("""
    d=$($B losetup -f) && $B losetup $d /run/volumes/late/vol-late.ext4 || exit 20
    $B mkdir -p /run/volumes/late-vol && $B mount -t ext4 $d /run/volumes/late-vol || exit 21
    echo "late volume on $d"
    for v in bootvol late-vol; do
      # busybox dd has no oflag=dsync: one dd per 4 KiB write, each fsynced.
      # Process start-up is in every figure, the same for both disks.
      # busybox date has no %N; /proc/uptime is in hundredths of a second.
      s=$($B cut -d' ' -f1 /proc/uptime | $B tr -d .)
      i=0; while [ $i -lt 300 ]; do
        $B dd if=/dev/zero of=/run/volumes/$v/sync bs=4096 count=1 seek=$i conv=fsync,notrunc 2>/dev/null; i=$((i+1))
      done
      e=$($B cut -d' ' -f1 /proc/uptime | $B tr -d .)
      echo "$v 300 x 4 KiB, each fsynced: $($B awk -v s="$s" -v e="$e" 'BEGIN { printf "%d", (e - s) * 10000 / 300 }') us per write, process start included (uptime $s -> $e)" 
      echo -n "$v 256 MiB sequential + fsync: "
      $B dd if=/dev/zero of=/run/volumes/$v/seq bs=1M count=256 conv=fsync 2>&1 | $B tail -1
      $B rm -f /run/volumes/$v/sync /run/volumes/$v/seq
    done
    echo "marker-$$-$($B date +%s)" > /run/volumes/late-vol/marker && $B sync /run/volumes/late-vol/marker
    echo "wrote: $($B cat /run/volumes/late-vol/marker)"
    """)
say("writable late disk", code)

// Copy the image on the Mac while the guest still has it mounted -- what a
// crash would leave -- and mount the copy read-only to see what reached it.
try clone(lateVolume, to: share.appending(component: "vol-late-copy.ext4"))
code = try await root("""
    d=$($B losetup -f) && $B losetup -r $d /run/volumes/late/vol-late-copy.ext4 || exit 30
    $B mkdir -p /run/volumes/late-copy
    $B mount -t ext4 -o ro,noload $d /run/volumes/late-copy || exit 31
    echo "the Mac's copy holds: $($B cat /run/volumes/late-copy/marker 2>&1)"
    """)
say("what reached the Mac's file after a synced write, without unmounting", code)

// 4. chown, which a virtiofs directory cannot do.
code = try await root("""
    $B touch /run/volumes/late-vol/owned && $B chown 1234:5678 /run/volumes/late-vol/owned
    $B ls -ln /run/volumes/late-vol/owned
    """, extra: [.chown, .fowner])
say("chown on the late volume", code)

// 5. Taking it away again, and the loop devices with it.
code = try await root("""
    for m in late-copy late-vol late-img; do
      d=$($B awk -v m=/run/volumes/$m '$2==m {print $1}' /proc/self/mounts)
      $B umount /run/volumes/$m && $B losetup -d $d && echo "detached $m ($d)"
    done
    echo "loop devices left: $($B losetup -a | $B wc -l)"
    """)
say("detach", code)

try await pod.stop()
print("\nstopped")
