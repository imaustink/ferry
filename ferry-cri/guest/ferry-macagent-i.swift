// ferry-macagent-i: the interactive half of a macOS pod's guest agent.
//
// The baked agent (experiments/39-macos-pods/agent.swift, vsock 7000) runs a
// command with stdin from /dev/null and streams its output back -- enough for a
// container's entrypoint, probes and non-interactive `kubectl exec`. This is its
// interactive sibling for `kubectl exec -i` / `-it`: it is uploaded into the
// guest and launched at runtime by ferry-cri (no change to the golden image), it
// listens on vsock 7001, and it wires the process's stdin -- with a PTY when a
// terminal is asked for -- so an interactive shell works.
//
// Per connection:
//   request:  one JSON line {"argv":[...],"env":{...},"chroot":"...","tty":bool}
//   then, both directions framed as [type u8][len u32 BE][payload]:
//     host -> guest: 0 = stdin, 4 = resize (payload = cols u16 BE, rows u16 BE)
//     guest -> host: 1 = stdout, 2 = stderr, 3 = exit (i32 BE), 4 = agent error

import Darwin
import Foundation

let port: UInt32 = 7001

struct Request: Decodable {
    var argv: [String]
    var env: [String: String]?
    var chroot: String?
    var tty: Bool?
}

final class Conn {
    let fd: Int32
    private let lock = NSLock()
    init(_ fd: Int32) { self.fd = fd }

    func send(_ type: UInt8, _ payload: [UInt8]) {
        var frame = [type]
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: payload)
        lock.lock(); defer { lock.unlock() }
        var off = 0
        while off < frame.count {
            let w = frame[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if w <= 0 { return }
            off += w
        }
    }

    func readByte() -> UInt8? { var b: UInt8 = 0; return read(fd, &b, 1) == 1 ? b : nil }

    func readLine() -> [UInt8]? {
        var line: [UInt8] = []
        while let b = readByte() { if b == 0x0A { return line }; line.append(b) }
        return line.isEmpty ? nil : line
    }

    func readN(_ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n); var off = 0
        while off < n { let r = buf[off...].withUnsafeMutableBytes { read(fd, $0.baseAddress, n - off) }
            if r <= 0 { return nil }; off += r }
        return buf
    }

    /// Next host->guest frame (type, payload).
    func readFrame() -> (UInt8, [UInt8])? {
        guard let t = readByte(), let lenB = readN(4) else { return nil }
        let len = (UInt32(lenB[0]) << 24) | (UInt32(lenB[1]) << 16) | (UInt32(lenB[2]) << 8) | UInt32(lenB[3])
        let payload = len == 0 ? [] : (readN(Int(len)) ?? [])
        return (t, payload)
    }
}

func setWinsize(_ fd: Int32, cols: UInt16, rows: UInt16) {
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(fd, TIOCSWINSZ, &ws)
}

func serve(_ conn: Conn) {
    defer { close(conn.fd) }
    guard let line = conn.readLine(),
          let req = try? JSONDecoder().decode(Request.self, from: Data(line)), !req.argv.isEmpty else {
        conn.send(4, Array("bad request".utf8)); return
    }
    var argv = req.argv
    if let root = req.chroot { argv = ["/usr/sbin/chroot", root] + argv }
    let tty = req.tty ?? false

    // A PTY for a terminal, else pipes. `inWrite`/`outRead`/`errRead` are our ends;
    // `childFds` are the process's ends, closed here right after the spawn so the
    // reads EOF when the process exits.
    var inWrite: Int32 = -1, outRead: Int32 = -1, errRead: Int32 = -1
    var childFds: [Int32] = []
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    if tty {
        var master: Int32 = 0, slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            conn.send(4, Array("openpty failed".utf8)); return
        }
        inWrite = master; outRead = master
        setWinsize(slave, cols: 80, rows: 24)           // a sane default until the client resizes
        posix_spawn_file_actions_adddup2(&actions, slave, 0)
        posix_spawn_file_actions_adddup2(&actions, slave, 1)
        posix_spawn_file_actions_adddup2(&actions, slave, 2)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addclose(&actions, master)
        childFds = [slave]                              // we keep master
    } else {
        var inP: [Int32] = [0, 0], outP: [Int32] = [0, 0], errP: [Int32] = [0, 0]
        pipe(&inP); pipe(&outP); pipe(&errP)
        inWrite = inP[1]; outRead = outP[0]; errRead = errP[0]
        posix_spawn_file_actions_adddup2(&actions, inP[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outP[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errP[1], 2)
        for fd in [inP[0], inP[1], outP[0], outP[1], errP[0], errP[1]] {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        childFds = [inP[0], outP[1], errP[1]]           // we keep inP[1], outP[0], errP[0]
    }

    var env = ProcessInfo.processInfo.environment
    env["PATH"] = env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if tty { env["TERM"] = env["TERM"] ?? "xterm" }
    for (k, v) in req.env ?? [:] { env[k] = v }
    let cArgv = argv.map { strdup($0) } + [nil]
    let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { cArgv.forEach { free($0) }; cEnv.forEach { free($0) } }

    var pid: pid_t = 0
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    if tty { posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)) }   // controlling tty
    let rc = posix_spawnp(&pid, argv[0], &actions, &attr, cArgv, cEnv)
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr)
    for fd in childFds { close(fd) }   // so our reads EOF when the process exits
    if rc != 0 {
        conn.send(4, Array("spawn \(argv[0]): \(String(cString: strerror(rc)))".utf8)); return
    }

    // guest -> host: stream the process output.
    func pump(_ from: Int32, _ type: UInt8) -> Thread {
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true { let n = read(from, &buf, buf.count); if n <= 0 { break }; conn.send(type, Array(buf[0..<n])) }
        }
        t.start(); return t
    }
    let outT = pump(outRead, 1)
    let errT = errRead >= 0 ? pump(errRead, 2) : nil

    // host -> guest: stdin and resize, until the connection closes.
    let inT = Thread {
        while let (type, payload) = conn.readFrame() {
            if type == 0 {                                   // stdin
                if payload.isEmpty { close(inWrite); continue }
                var off = 0
                while off < payload.count {
                    let w = payload[off...].withUnsafeBytes { write(inWrite, $0.baseAddress, payload.count - off) }
                    if w <= 0 { break }; off += w
                }
            } else if type == 4, payload.count >= 4, tty {   // resize
                let cols = (UInt16(payload[0]) << 8) | UInt16(payload[1])
                let rows = (UInt16(payload[2]) << 8) | UInt16(payload[3])
                setWinsize(inWrite, cols: cols, rows: rows)
            }
        }
    }
    inT.start()

    var status: Int32 = 0
    waitpid(pid, &status, 0)
    if tty { close(inWrite) } else { close(inWrite) }   // let the input thread unwind
    while !outT.isFinished || (errT.map { !$0.isFinished } ?? false) { usleep(1000) }
    let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    conn.send(3, withUnsafeBytes(of: code.bigEndian) { Array($0) })
}

// Close any fds inherited from the baked agent that launched us (its vsock
// listener, the install connection, its pipes) so that install exec is not held
// open and returns -- we open only our own listener below.
for fd in Int32(3)..<256 { close(fd) }

let listener = socket(AF_VSOCK, SOCK_STREAM, 0)
guard listener >= 0 else { perror("socket"); exit(1) }
var addr = sockaddr_vm()
addr.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
addr.svm_family = sa_family_t(AF_VSOCK)
addr.svm_port = port
addr.svm_cid = UInt32.max   // VMADDR_CID_ANY
let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
    }
}
guard bound == 0, listen(listener, 16) == 0 else { perror("bind/listen"); exit(1) }
print("ferry-macagent-i: listening on vsock port \(port)")
while true {
    let fd = accept(listener, nil, nil)
    if fd < 0 { continue }
    Thread { serve(Conn(fd)) }.start()
}
