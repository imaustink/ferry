// The line ClockService hands a machine's init, which passes it to
// `date -s @<line>`: whole seconds, a dot, and six digits of microseconds, so a
// reading early in a second is not read as a tenth of one.

import Foundation
import Testing
@testable import ferry_node

@Suite struct ClockServiceTests {
    @Test func secondsAndZeroPaddedMicroseconds() {
        #expect(clockReading(timeval(tv_sec: 1_795_727_550, tv_usec: 42)) == "1795727550.000042\n")
        #expect(clockReading(timeval(tv_sec: 1_795_727_550, tv_usec: 999_999)) == "1795727550.999999\n")
        #expect(clockReading(timeval(tv_sec: 0, tv_usec: 0)) == "0.000000\n")
    }

    @Test func thePortMatchesTheGuests() throws {
        let init_ = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/ferry-node-tests/ClockServiceTests.swift", with: "init.sh"),
            encoding: .utf8)
        #expect(init_.contains("CLOCK_PORT=\(clockServicePort)"))
    }
}
