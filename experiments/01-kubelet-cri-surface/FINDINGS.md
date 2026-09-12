# Experiment 01 — How much of the kubelet works on macOS?

**Question.** The darwin kubelet compiles and starts, but dies the moment it
looks for a CRI socket. Once a runtime answers, how much further does it get,
and how large is the patch needed to make it useful?

**Method.** `fakecri` is a CRI runtime that creates nothing — every sandbox and
container is a map entry. It logs every call. Point a darwin/arm64 kubelet at
it in standalone mode with a static pod manifest and see what breaks, patching
forward until it stops breaking.

Nothing here involves a hypervisor, a VM, or a Linux guest.

## Result

The kubelet drove a **complete pod lifecycle**:

```
RunPodSandbox → PodSandboxStatus → ImageStatus → PullImage → ImageStatus
  → CreateContainer → StartContainer
  → ContainerStatus / ReopenContainerLog / Status  (steady state)
```

210 CRI calls over 50s, **zero fatal errors**, PLEG healthy, node conditions
(`NodeHasSufficientMemory`, `NodeHasNoDiskPressure`, `NodeHasSufficientPID`)
reported from real machine facts.

## The walls, in the order they appeared

| # | Failure | Fatal | Resolution |
|---|---|---|---|
| 1 | no CRI endpoint | yes | the experiment itself |
| 2 | `RuntimeConfig` unimplemented | **no** | kubelet logs it and falls back to its own cgroup driver config |
| 3 | `cAdvisor is unsupported in this build` | yes | `cadvisor_darwin.go` — sysctl + statfs |
| 4 | `volume/util/hostutil on this platform is not supported` | yes | `hostutil_darwin.go` — plain stat work |
| 5 | `mkdir /var/log/containers: permission denied` | yes | not architectural; kubelet runs as root in production. Overridable var used instead. |
| 6 | `Container Manager is unsupported in this build` | yes | `container_manager_darwin.go` — 15 lines over the existing stub |

## Patch surface

| File | Lines | What it does |
|---|---|---|
| `pkg/kubelet/cadvisor/cadvisor_darwin.go` | ~180 | machine info from `sysctl`, fs info from `statfs`; container stats deliberately empty |
| `pkg/volume/util/hostutil/hostutil_darwin.go` | ~110 | stat-based file queries; mount propagation and SELinux report absence |
| `pkg/kubelet/cm/container_manager_darwin.go` | ~15 | returns the upstream stub, whose `Start()` already succeeds |
| `pkg/kubelet/container_logs_dir_darwin.go` | ~10 | honours an override for the container log root |

Roughly **300 lines**, no upstream logic reimplemented, plus three build-tag
widenings so the darwin files win over `!linux && !windows` fallbacks.

`containerManagerStub` deserves specific mention: it is a complete 35-method
`ContainerManager` whose `Start()` already returns nil. Upstream keeps it for
tests. On darwin it is the correct implementation, not a placeholder — when a
pod is a VM, the hypervisor bounds its resources and there is no host cgroup
tree to program.

## Residual non-fatal issues

| Issue | Real? | Note |
|---|---|---|
| eviction manager: "failed to get root cgroup stats" | **yes** | needs a synthetic root entry in `ContainerInfoV2`, or eviction sourced from CRI. Retries every 10s; harmless but noisy. |
| `Watching source file is unsupported in this build` | **yes** | `pkg/kubelet/config/file_unsupported.go`; static pods fell back to polling and still worked. fsnotify supports darwin, so this is a build-tag fix. |
| dynamic plugin prober: `mkdir /usr/libexec/kubernetes` | **yes** | CSI plugin directory; needs a configurable path or root. |
| `SetRLimit unsupported in this platform` | minor | cosmetic |
| `could not read "/proc"` | minor | cosmetic |
| "failed to stat container log after reopen" | no | artifact of the fake returning a log path it never creates |
| image GC "found 0 bytes eligible" | no | artifact of the fake's invented `ImageFsInfo` |
| "needs to run as uid 0" | no | production runs it as a launchd daemon |

## Conclusion

The kubelet is not the hard part. A working darwin kubelet is ~300 lines of
platform glue over unmodified upstream code, and every wall hit was a missing
platform implementation with an existing interface to fill — never a design
assumption that a pod must be a Linux process on the local kernel.

The remaining risk moves entirely to the runtime: implementing CRI against the
Containerization framework, and the concurrent-VM ceiling.

## Reproduce

```sh
./build-kubelet.sh          # clones upstream, applies patches/kubelet overlay
cd experiments/01-kubelet-cri-surface
go build -o ../../bin/fakecri .
SECS=50 ./run.sh
cat /tmp/ferry-e01/fakecri.log
```
