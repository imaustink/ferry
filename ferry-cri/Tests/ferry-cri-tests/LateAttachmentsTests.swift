// Mounts made into a running pod VM after boot. PodRuntime re-enters at each
// await of an attach, so CreateContainer calls for one pod overlap; these
// check that overlapping attaches never share a file or mountpoint, and that
// the same image or volume is attached once.

import Synchronization
import Testing
@testable import ferry_cri

/// Atomic is noncopyable, so a task group's closures share it through this.
private final class Counter: Sendable {
    let value = Atomic<Int>(0)
}

@Suite struct LateAttachmentsTests {
    @Test func overlappingAttachesOfDifferentKeysGetDistinctIndices() async throws {
        let late = LateAttachments()
        let mountpoints: [String] = try await withThrowingTaskGroup(of: String.self) { group in
            for image in ["a", "b", "c", "d"] {
                group.addTask {
                    try await late.attach(image) { index in
                        try await Task.sleep(for: .milliseconds(20))   // held across an await
                        return "/run/volumes/ferry_late_\(index)"
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(mountpoints).count == 4)
        #expect(late.mounts.count == 4)
    }

    @Test func overlappingAttachesOfOneKeyAttachOnce() async throws {
        let late = LateAttachments()
        let runs = Counter()
        let mountpoints: [String] = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await late.attach("image") { index in
                        runs.value.wrappingAdd(1, ordering: .relaxed)
                        try await Task.sleep(for: .milliseconds(20))
                        return "/run/volumes/ferry_late_\(index)"
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(runs.value.load(ordering: .relaxed) == 1)
        #expect(Set(mountpoints) == ["/run/volumes/ferry_late_0"])
        #expect(late.mounted("image") == "/run/volumes/ferry_late_0")
    }

    @Test func aFailedAttachsIndexIsNeverReused() async throws {
        struct Timeout: Error {}
        let late = LateAttachments()
        await #expect(throws: Timeout.self) {
            try await late.attach("image") { _ in throw Timeout() }
        }
        #expect(late.mounted("image") == nil)
        // The retry may not reuse the first attempt's file: its mount could
        // still complete after the timeout.
        let retried = try await late.attach("image") { "/run/volumes/ferry_late_\($0)" }
        #expect(retried == "/run/volumes/ferry_late_1")
        let other = try await late.attach("other") { "/run/volumes/ferry_late_\($0)" }
        #expect(other == "/run/volumes/ferry_late_2")
    }
}
