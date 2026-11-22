// What a container's cgroup gets inside its pod's VM. Since Containerization
// 0.47 every container's limits are applied, at 4 CPUs and 1 GiB unless set,
// so a container the kubelet gave no limit must be given the VM's size rather
// than be left to that default.

import Containerization
import Testing
@testable import ferry_cri

@Suite struct ContainerLimitsTests {
    let vm = VMResources(cpus: 6, memoryInBytes: 3 << 30)

    @Test func noLimitIsTheWholeMachine() {
        let limits = PodRuntime.containerLimits(memoryLimit: 0, cpuQuota: 0, cpuPeriod: 0, vm: vm)
        #expect(limits.cpus == 6)
        #expect(limits.memoryInBytes == 3 << 30)
    }

    @Test func aLimitIsKept() {
        // 300Mi and 1500m, which rounds up to two whole CPUs.
        let limits = PodRuntime.containerLimits(memoryLimit: 300 << 20, cpuQuota: 150_000,
                                                cpuPeriod: 100_000, vm: vm)
        #expect(limits.cpus == 2)
        #expect(limits.memoryInBytes == 300 << 20)
    }

    @Test func aRequestAloneIsNoCPULimit() {
        // The kubelet sends shares for a request and no quota.
        let limits = PodRuntime.containerLimits(memoryLimit: 0, cpuQuota: 0, cpuPeriod: 100_000, vm: vm)
        #expect(limits.cpus == 6)
    }

    @Test func anOOMKillTakesTheWholeContainer() {
        #expect(PodRuntime.containerUnified(kubelet: [:]) == ["memory.oom.group": "1"])
    }

    @Test func whatTheKubeletSendsWins() {
        let unified = PodRuntime.containerUnified(kubelet: ["memory.oom.group": "0", "memory.high": "max"])
        #expect(unified == ["memory.oom.group": "0", "memory.high": "max"])
    }
}
