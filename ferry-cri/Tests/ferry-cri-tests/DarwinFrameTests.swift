// The guest exec protocol's frame parser (DarwinSandbox.swift) is the one part
// of the darwin sandbox that can be tested without booting a macOS VM.

import Foundation
import Testing
@testable import ferry_cri

@Suite struct DarwinFrameTests {
    /// Builds a wire frame the way agent.swift does: [type][len u32 BE][payload].
    private func frame(_ kind: DarwinFrameKind, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [kind.rawValue]
        let n = UInt32(payload.count)
        out.append(UInt8((n >> 24) & 0xff))
        out.append(UInt8((n >> 16) & 0xff))
        out.append(UInt8((n >> 8) & 0xff))
        out.append(UInt8(n & 0xff))
        out.append(contentsOf: payload)
        return out
    }

    @Test func parsesAWholeFrame() throws {
        var p = DarwinFrameParser()
        let frames = try p.feed(frame(.stdout, Array("hello".utf8)))
        #expect(frames == [DarwinFrame(kind: .stdout, payload: Array("hello".utf8))])
        #expect(p.isDrained)
    }

    @Test func reassemblesFramesSplitAcrossReads() throws {
        var p = DarwinFrameParser()
        let whole = frame(.stderr, Array("oops".utf8))
        // Feed it one byte at a time: nothing until the last byte completes it.
        var got: [DarwinFrame] = []
        for (i, b) in whole.enumerated() {
            let out = try p.feed([b])
            if i < whole.count - 1 { #expect(out.isEmpty) }
            got.append(contentsOf: out)
        }
        #expect(got == [DarwinFrame(kind: .stderr, payload: Array("oops".utf8))])
        #expect(p.isDrained)
    }

    @Test func yieldsSeveralFramesFromOneFeed() throws {
        var p = DarwinFrameParser()
        var bytes = frame(.stdout, Array("a".utf8))
        bytes.append(contentsOf: frame(.stdout, Array("b".utf8)))
        bytes.append(contentsOf: frame(.exit, [0, 0, 0, 0]))
        let frames = try p.feed(bytes)
        #expect(frames.count == 3)
        #expect(frames[2].kind == .exit)
    }

    @Test func decodesTheExitStatus() {
        #expect(DarwinFrameParser.exitStatus([0, 0, 0, 0]) == 0)
        #expect(DarwinFrameParser.exitStatus([0, 0, 0, 1]) == 1)
        // 128 + signal, the way the agent reports a killed process.
        #expect(DarwinFrameParser.exitStatus([0, 0, 0, 137]) == 137)
    }

    @Test func rejectsAnUnknownFrameKind() {
        var p = DarwinFrameParser()
        #expect(throws: DarwinFrameError.self) {
            _ = try p.feed([9, 0, 0, 0, 0]) // kind 9 is not a frame type
        }
    }

    @Test func aRunRequestRoundTrips() throws {
        let req = DarwinRunRequest(argv: ["/bin/echo", "hi"], env: ["A": "b"], cwd: "/tmp", chroot: "/root")
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(DarwinRunRequest.self, from: data)
        #expect(back.argv == ["/bin/echo", "hi"])
        #expect(back.env == ["A": "b"])
        #expect(back.cwd == "/tmp")
        #expect(back.chroot == "/root")
    }
}
