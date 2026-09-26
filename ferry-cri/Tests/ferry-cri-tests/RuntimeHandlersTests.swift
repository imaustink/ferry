// Which RuntimeClass handlers ferry-cri runs, and which it refuses.
//
// ferry-cri ignored RunPodSandboxRequest.runtime_handler, so a pod whose
// class named containerd's `runc` -- a ferry-shared pod that reached the Mac --
// was started as a VM without a word. The CRI says an unknown handler is to be
// refused.

import Testing
@testable import ferry_cri

@Suite struct RuntimeHandlersTests {
    @Test func aPodThatNamesNoRuntimeClassRuns() {
        #expect(RuntimeHandlers.refusal(for: "") == nil)
    }

    @Test func ferryVMRuns() {
        #expect(RuntimeHandlers.refusal(for: "ferry-vm") == nil)
    }

    @Test(arguments: ["runc", "kata", "gvisor", "ferry-shared", "FERRY-VM", " ferry-vm"])
    func anyOtherHandlerIsRefused(_ handler: String) throws {
        let refusal = try #require(RuntimeHandlers.refusal(for: handler))
        #expect(refusal.contains("no runtime handler \"\(handler)\""))
    }

    @Test func theRefusalSaysWhereSuchAPodBelongs() throws {
        let refusal = try #require(RuntimeHandlers.refusal(for: "runc"))
        #expect(refusal.contains("ferry-shared pods run on machines"))
        #expect(refusal.contains("kubectl get nodes -L ferry.dev/mode"))
    }

    // What node.status.runtimeHandlers is built from: every handler that runs,
    // and nothing that is refused.
    @Test func theServedListMatchesWhatRuns() {
        #expect(RuntimeHandlers.served == ["", "ferry-vm"])
        for handler in RuntimeHandlers.served {
            #expect(RuntimeHandlers.refusal(for: handler) == nil)
        }
    }
}
