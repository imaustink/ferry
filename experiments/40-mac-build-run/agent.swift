// ferry-macagent: the guest half of a macOS pod.
//
// A Linux pod VM has vminitd, which Apple's framework talks to over vsock. A
// macOS guest has nothing listening, so this is the smallest stand-in: a
// launchd daemon that accepts one request per vsock connection, runs it, and
// streams the result back. It runs as root before anyone logs in, which is the
// only reason a freshly installed macOS -- still sitting at Setup Assistant --
// is usable as a pod at all.
//
// Request:  one JSON line, {"argv": [...], "env": {...}, "cwd": "...", "chroot": "..."}
// Response: frames of [type u8][length u32 BE][payload];
//           1 = stdout, 2 = stderr, 3 = exit status (i32 BE), 4 = agent error.

import Darwin
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let port: UInt32 = 7000

struct Request: Decodable {
    var argv: [String]
    var env: [String: String]?
    var cwd: String?
    var chroot: String?
}

final class Connection {
    let fd: Int32
    private let lock = NSLock()
    init(fd: Int32) { self.fd = fd }

    func send(_ type: UInt8, _ payload: [UInt8]) {
        var frame = [type]
        let n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: n) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: payload)
        lock.lock()
        defer { lock.unlock() }
        var off = 0
        while off < frame.count {
            let w = frame[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if w <= 0 { return }
            off += w
        }
    }

    func readLine() -> [UInt8]? {
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return line.isEmpty ? nil : line
    }
}

func pump(_ from: Int32, _ type: UInt8, _ conn: Connection) -> Thread {
    let t = Thread {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(from, &buf, buf.count)
            if n <= 0 { break }
            conn.send(type, Array(buf[0..<n]))
        }
        close(from)
    }
    t.start()
    return t
}

func serve(_ conn: Connection) {
    defer { close(conn.fd) }
    guard let line = conn.readLine(),
          let req = try? JSONDecoder().decode(Request.self, from: Data(line)),
          !req.argv.isEmpty else {
        conn.send(4, Array("bad request".utf8))
        return
    }
    var argv = req.argv
    if let root = req.chroot { argv = ["/usr/sbin/chroot", root] + argv }

    var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
    pipe(&outPipe)
    pipe(&errPipe)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
    posix_spawn_file_actions_addclose(&actions, outPipe[0])
    posix_spawn_file_actions_addclose(&actions, errPipe[0])
    if let cwd = req.cwd { posix_spawn_file_actions_addchdir(&actions, cwd) }

    var env = ProcessInfo.processInfo.environment
    env["PATH"] = env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for (k, v) in req.env ?? [:] { env[k] = v }

    let cArgv = argv.map { strdup($0) } + [nil]
    let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { cArgv.forEach { free($0) }; cEnv.forEach { free($0) } }

    var pid: pid_t = 0
    let rc = posix_spawnp(&pid, argv[0], &actions, nil, cArgv, cEnv)
    posix_spawn_file_actions_destroy(&actions)
    close(outPipe[1])
    close(errPipe[1])
    if rc != 0 {
        close(outPipe[0]); close(errPipe[0])
        conn.send(4, Array("spawn \(argv[0]): \(String(cString: strerror(rc)))".utf8))
        return
    }
    let a = pump(outPipe[0], 1, conn), b = pump(errPipe[0], 2, conn)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    while !a.isFinished || !b.isFinished { usleep(1000) }
    let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    var be = code.bigEndian
    conn.send(3, withUnsafeBytes(of: &be) { Array($0) })
}

let listener = socket(AF_VSOCK, SOCK_STREAM, 0)
guard listener >= 0 else { perror("socket"); exit(1) }
var addr = sockaddr_vm()
addr.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
addr.svm_family = sa_family_t(AF_VSOCK)
addr.svm_port = port
addr.svm_cid = UInt32.max  // VMADDR_CID_ANY
let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
    }
}
guard bound == 0, listen(listener, 16) == 0 else { perror("bind/listen"); exit(1) }
print("ferry-macagent: listening on vsock port \(port)")

while true {
    let fd = accept(listener, nil, nil)
    if fd < 0 { continue }
    Thread { serve(Connection(fd: fd)) }.start()
}
