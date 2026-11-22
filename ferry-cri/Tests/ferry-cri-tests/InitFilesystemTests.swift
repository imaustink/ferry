// The guest agent's unpacked filesystem is named for the image it came from,
// so an upgraded ferry-cri cannot boot pods with the agent it replaced.

import Foundation
import Testing
@testable import ferry_cri

@Suite struct InitFilesystemTests {
    @Test func namedForTheAgentsDigest() {
        let a = PodRuntime.initFilesystemName(digest: "sha256:0123456789abcdef0123")
        let b = PodRuntime.initFilesystemName(digest: "sha256:fedcba9876543210fedc")
        #expect(a == "init-0123456789abcdef.ext4")
        #expect(a != b)
    }

    @Test func staleAgentsAreRemovedAndNothingElse() throws {
        let dir = FileManager.default.temporaryDirectory.appending(component: "ferry-init-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["init.ext4", "init-aaaaaaaaaaaaaaaa.ext4", "init-bbbbbbbbbbbbbbbb.ext4",
                     "images.json", "init-notes.txt"] {
            FileManager.default.createFile(atPath: dir.appending(component: name).path(), contents: Data())
        }
        PodRuntime.removeStaleInitFilesystems(in: dir, keeping: "init-bbbbbbbbbbbbbbbb.ext4")
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path()))
        #expect(left == ["init-bbbbbbbbbbbbbbbb.ext4", "images.json", "init-notes.txt"])
    }
}
