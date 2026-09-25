// A machine's root-disk barrier: the Machine's own, else the server's, else
// fsync. Measured on a live cluster (tests/e2e/runtime.sh), 300 write+sync
// rounds in a pod took 1.7-1.8s at full against 0.1-0.8s at fsync or none --
// so the wrong one here is either a durability promise broken or a machine
// several times slower than asked for. fsync and none are too close to tell
// apart by timing on an SSD; that they are chosen correctly is this suite.

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
