// Stopping cleanly on a signal, from a handler that is allowed to run.
//
// ferry-cri installed a signal handler for years and never once ran it. The
// handler looked right, `ferry down` gave it ten seconds, and the process died
// in one -- with a crash report nobody was looking for:
//
//     libdispatch           _dispatch_assert_queue_fail
//     libswift_Concurrency  _swift_task_checkIsolatedSwift
//     ferry-cri             closure #1 in closure #14
//     libdispatch           _dispatch_source_latch_and_call
//
// Top-level code in main.swift is `@MainActor`-isolated, so a closure written
// there inherits main-actor isolation. A dispatch signal source calls its
// handler on whatever queue it was given, and Swift's isolation check traps
// when that is not the main queue. The result is a SIGTRAP one second after
// SIGTERM, which from outside is indistinguishable from a process that simply
// exited on the signal -- and the `print` that would have said otherwise was
// still sitting in a block-buffered stdout that was never flushed.
//
// What it cost: pods were never stopped on `ferry down`, and the vmnet network
// was never released -- which is most of why a restart had a subnet to wait for
// at all (experiment 22).
//
// The fix is for the handler not to be main-actor isolated. Taking it as a
// `@Sendable` parameter of a function declared here rather than in top-level
// code is what does that: `@Sendable` closures cannot carry actor isolation, so
// the body runs wherever dispatch calls it and the check has nothing to trap on.

import Foundation
import Synchronization

/// Set once a signal has asked the process to stop. The CRI server's serve()
/// returns during that graceful shutdown as well as when something breaks it,
/// and only the second deserves a non-zero exit.
let shutdownRequested = Atomic<Bool>(false)

/// Runs `body` on SIGTERM or SIGINT, off the main queue.
///
/// The returned sources have to be kept alive by the caller: a cancelled or
/// deallocated `DispatchSourceSignal` stops delivering, silently.
func onShutdownSignal(_ body: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
    // Ignored at the disposition level first, or the default action kills the
    // process before the source ever sees it.
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    return [SIGTERM, SIGINT].map { sig in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler(handler: body)
        source.resume()
        return source
    }
}

/// Says what is happening, and makes sure it is actually said.
///
/// stdout is a log file here, so it is block-buffered: without the flush, a
/// line printed on the way out is lost if anything goes wrong afterwards --
/// which is exactly how the crash above stayed invisible.
func announce(_ message: String) {
    print(message)
    fflush(stdout)
}
