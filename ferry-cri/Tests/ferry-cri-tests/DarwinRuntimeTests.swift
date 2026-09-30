// DarwinRuntime's record/lifecycle bookkeeping, exercised without booting a
// guest (boot is lazy, on the first startContainer, which needs Mac hardware).
// What is covered here: availability, the golden-image and ceiling gates, and
// the sandbox/container record lifecycle the CRI methods read back.

import Foundation
import Testing
@testable import ferry_cri

@Suite struct DarwinRuntimeTests {
    private func sandboxConfig(name: String = "pod", ns: String = "default") -> Runtime_V1_PodSandboxConfig {
        var m = Runtime_V1_PodSandboxMetadata()
        m.name = name; m.uid = "uid-\(name)"; m.namespace = ns; m.attempt = 0
        var cfg = Runtime_V1_PodSandboxConfig()
        cfg.metadata = m
        cfg.labels = ["app": name]
        return cfg
    }

    private func containerConfig(name: String = "c", image: String = "app-darwin:1") -> Runtime_V1_ContainerConfig {
        var m = Runtime_V1_ContainerMetadata()
        m.name = name
        var spec = Runtime_V1_ImageSpec()
        spec.image = image
        var cfg = Runtime_V1_ContainerConfig()
        cfg.metadata = m
        cfg.image = spec
        cfg.command = ["/bin/app"]
        cfg.args = ["--serve"]
        return cfg
    }

    private func runtime(golden: String?) -> DarwinRuntime {
        DarwinRuntime(config: .init(
            golden: golden,
            stateDir: URL(filePath: NSTemporaryDirectory()).appendingPathComponent("darwin-test-\(UUID().uuidString)"),
            defaultCPUs: 4, defaultMemoryBytes: 4 << 30, maxGuests: 2, nodeIP: "192.0.2.1"))
    }

    @Test func withNoGoldenImageDarwinIsUnavailable() async throws {
        let d = runtime(golden: nil)
        #expect(await d.available == false)
        await #expect(throws: DarwinRuntimeError.self) {
            _ = try await d.runPodSandbox(config: sandboxConfig())
        }
    }

    @Test func aSandboxIsCreatedAndFound() async throws {
        let d = runtime(golden: "/tmp/fake-golden") // never booted, so never read
        #expect(await d.available)
        let id = try await d.runPodSandbox(config: sandboxConfig(name: "build"))
        #expect(await d.hasSandbox(id))
        let info = try await d.sandboxStatus(id)
        #expect(info.name == "build")
        #expect(info.ready)
        #expect(await d.listSandboxes().count == 1)
    }

    @Test func aContainerIsRecordedAgainstItsSandbox() async throws {
        let d = runtime(golden: "/tmp/fake-golden")
        let sid = try await d.runPodSandbox(config: sandboxConfig())
        let cid = try await d.createContainer(sandboxID: sid, config: containerConfig(name: "web"))
        #expect(await d.hasContainer(cid))
        let c = try await d.containerStatus(cid)
        #expect(c.name == "web")
        #expect(c.sandboxID == sid)
        #expect(c.state == .created)
        #expect(await d.listContainers().count == 1)
    }

    @Test func aContainerNeedsAnExistingSandbox() async throws {
        let d = runtime(golden: "/tmp/fake-golden")
        await #expect(throws: DarwinRuntimeError.self) {
            _ = try await d.createContainer(sandboxID: "nope", config: containerConfig())
        }
    }

    @Test func removingASandboxForgetsItsContainers() async throws {
        let d = runtime(golden: "/tmp/fake-golden")
        let sid = try await d.runPodSandbox(config: sandboxConfig())
        let cid = try await d.createContainer(sandboxID: sid, config: containerConfig())
        try await d.removePodSandbox(sid)
        #expect(await d.hasSandbox(sid) == false)
        #expect(await d.hasContainer(cid) == false)
        #expect(await d.listSandboxes().isEmpty)
    }
}
