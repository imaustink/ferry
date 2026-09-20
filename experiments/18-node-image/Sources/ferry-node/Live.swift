// The machines this process is hosting.
//
// A dictionary in `serve()` was enough while the only reader was the loop that
// owned it. The shutdown handler is a second reader, on another queue, and it
// has to see the same machines -- so the dictionary moved behind a lock rather
// than being captured and quietly copied.

import Foundation

@available(macOS 26.0, *)
final class Live: @unchecked Sendable {
    private var machines: [String: RunningMachine] = [:]
    private let lock = NSLock()

    func add(_ name: String, _ machine: RunningMachine) {
        lock.lock(); defer { lock.unlock() }
        machines[name] = machine
    }

    func remove(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        machines.removeValue(forKey: name)
    }

    func all() -> [String: RunningMachine] {
        lock.lock(); defer { lock.unlock() }
        return machines
    }

    /// Everything, and leaves the set empty: shutdown stops each machine once,
    /// even if the loop is running at the same time.
    func take() -> [String: RunningMachine] {
        lock.lock(); defer { lock.unlock() }
        let all = machines
        machines.removeAll()
        return all
    }
}
