// Every node on a Mac unpacks into one snapshot directory and runs from a hard
// link of its own, so a snapshot's link count is how many nodes hold it. These
// run the link counting, the sweep and the upgrade move on a temp directory.

import Foundation
import Testing
@testable import ferry_cri

@Suite struct SharedSnapshotsTests {
    private let fm = FileManager.default

    private func tempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appending(component: "ferry-snapshots-\(UUID())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL) {
        fm.createFile(atPath: url.path(percentEncoded: false), contents: Data("disk".utf8))
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test func releasingTheLastLinkDeletesTheSnapshot() throws {
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let shared = root.appending(component: "snapshots")
        let node = root.appending(component: "images")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try fm.createDirectory(at: node, withIntermediateDirectories: true)
        let snapshot = shared.appending(component: "k.ext4")
        let mine = node.appending(component: "k.ext4")
        touch(snapshot)
        try fm.linkItem(at: snapshot, to: mine)
        #expect(PodRuntime.linkCount(snapshot.path(percentEncoded: false)) == 2)

        PodRuntime.releaseDisk(mine.path(percentEncoded: false), snapshots: shared)
        #expect(!exists(mine))
        #expect(!exists(snapshot))
    }

    @Test func releasingOneNodesLinkKeepsAnotherNodesSnapshot() throws {
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let shared = root.appending(component: "snapshots")
        let a = root.appending(component: "a")
        let b = root.appending(component: "b")
        for dir in [shared, a, b] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let snapshot = shared.appending(component: "k.ext4")
        touch(snapshot)
        try fm.linkItem(at: snapshot, to: a.appending(component: "k.ext4"))
        try fm.linkItem(at: snapshot, to: b.appending(component: "k.ext4"))

        PodRuntime.releaseDisk(a.appending(component: "k.ext4").path(percentEncoded: false), snapshots: shared)
        #expect(exists(snapshot))
        #expect(exists(b.appending(component: "k.ext4")))
        #expect(PodRuntime.linkCount(snapshot.path(percentEncoded: false)) == 2)
    }

    @Test func theSweepTakesOnlyUnlinkedSnapshotsAndDeadUnpacks() throws {
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let shared = root.appending(component: "snapshots")
        let node = root.appending(component: "images")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try fm.createDirectory(at: node, withIntermediateDirectories: true)
        for name in ["linked.ext4", "unlinked.ext4", "k.lock", ".fresh.tmp", ".dead.tmp"] {
            touch(shared.appending(component: name))
        }
        try fm.linkItem(at: shared.appending(component: "linked.ext4"), to: node.appending(component: "linked.ext4"))
        let old = Date().addingTimeInterval(-2 * 86_400)
        try fm.setAttributes([.modificationDate: old],
                             ofItemAtPath: shared.appending(component: ".dead.tmp").path(percentEncoded: false))

        let unused = Set(PodRuntime.unusedSnapshots(in: shared.path(percentEncoded: false))
            .map { ($0 as NSString).lastPathComponent })
        #expect(unused == ["unlinked.ext4", ".dead.tmp"])
    }

    @Test func snapshotsFromBeforeSharingMoveIntoTheSharedDirectory() throws {
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let old = root.appending(component: "cri/snapshots")
        let shared = root.appending(component: "snapshots")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        for name in ["a.ext4", "b.ext4", ".c.ext4.tmp", "a.lock"] { touch(old.appending(component: name)) }
        fm.createFile(atPath: shared.appending(component: "b.ext4").path(percentEncoded: false),
                      contents: Data("already shared".utf8))

        PodRuntime.moveSnapshots(from: old, into: shared)
        #expect(!exists(old))
        let left = Set(try fm.contentsOfDirectory(atPath: shared.path(percentEncoded: false)))
        #expect(left == ["a.ext4", "b.ext4"])
        let b = try Data(contentsOf: shared.appending(component: "b.ext4"))
        #expect(String(decoding: b, as: UTF8.self) == "already shared")
    }

    @Test func movingIsANoOpWhenTheDirectoriesAreTheSame() throws {
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let dir = root.appending(component: "snapshots")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        touch(dir.appending(component: "a.ext4"))
        PodRuntime.moveSnapshots(from: dir, into: dir)
        #expect(exists(dir.appending(component: "a.ext4")))
    }
}
