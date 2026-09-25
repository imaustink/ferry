// A machine's root-disk barrier: the Machine's own, else the server's, else
// fsync. Measured on a live cluster, 300 write+sync rounds in a pod took
// 1.81s at full, 0.79s at fsync and 0.12s at none -- so the wrong one here is
// either a durability promise broken or a machine three times slower than
// asked for.

import Testing
import Virtualization
@testable import ferry_node

@Suite struct DiskSyncTests {
    @Test func aMachineThatSaysNothingTakesTheServers() {
        #expect(diskSynchronizationMode(nil, serverDefault: "none") == .none)
        #expect(diskSynchronizationMode(nil, serverDefault: "full") == .full)
        #expect(diskSynchronizationMode(nil, serverDefault: "fsync") == .fsync)
    }

    @Test func aMachinesOwnWinsOverTheServers() {
        #expect(diskSynchronizationMode("full", serverDefault: "none") == .full)
        #expect(diskSynchronizationMode("none", serverDefault: "full") == .none)
        #expect(diskSynchronizationMode("fsync", serverDefault: "none") == .fsync)
    }

    @Test func nothingSaidAnywhereIsFsync() {
        #expect(diskSynchronizationMode(nil, serverDefault: nil) == .fsync)
        #expect(diskSynchronizationMode(nil, serverDefault: "") == .fsync)
    }

    // Not a guess in either direction: an unknown word is the barrier ferry
    // has always used.
    @Test func anUnknownWordIsFsync() {
        #expect(diskSynchronizationMode("power-loss", serverDefault: "none") == .fsync)
        #expect(diskSynchronizationMode(nil, serverDefault: "relaxed") == .fsync)
    }
}
