# Experiment 38: a churn soak, and the kubelet's connection to ferry-cri

**Question.** Experiment 03 showed that 128 VMs *start*. Does a node stay the same after thousands of pods have come and gone? Do teardown and reuse leak anything?

**The harness.** `soak.sh` repeats three workloads and snapshots the Mac after each cycle has drained:

- **scale:** a Deployment behind a Service goes from 0 to 20 pods and back. It checks for 20 ready endpoints, an exec with a request through the Service, and a log read.
- **job:** a Job of 30 one-second pods, 10 at a time.
- **abort:** 10 pods, each force-deleted 0–3 s after it is created.

`snapshot.sh` counts what this profile holds on the Mac:

- for each component: open files, memory and threads;
- pod VMs, and the files, sockets and disk space under the runtime directory;
- the state directory and the size of the etcd database;
- vmnet interfaces, and sockets by state;
- what is left in the soak namespace.

`report.py` flags any count still growing in the second half of the run. `series.py` prints chosen columns side by side.

```
./soak.sh --hours 3                   # or --cycles N, --workloads scale,job,abort
python3 series.py ferry_cri_fds results/<run>/snapshots.csv
```

## What it found: the kubelet's CRI connection was being cut

The first run failed in its first ten minutes. Some pods crash-looped with `httpd: bind: Address already in use` and never became Ready. That happened in 3 of 12 scale-ups from 0 to 20. The pod is its own VM, so nothing else in it should hold that port.

**Two containers in one pod.** The kubelet made a second container for `web` while the first was still starting. The first then came up anyway and held the port, so every restart of the second failed. ferry-cri's trace showed two StartContainer calls for the same container:

| t | |
|---|---|
| 30.529 | StartContainer #1 arrives and boots the VM |
| 32.322 | **StartContainer #2** arrives for the same container |
| 32.326 | #2 finds #1 in flight and returns OK. The container is still CREATED |
| 32.338 | the kubelet reads CREATED as a start that failed, and makes a new container |
| 32.417 | #1 finishes, and the first container is running |

**Why the kubelet sent it twice.** The kubelet logged `rpc error: code = Unavailable desc = error reading from server: unexpected EOF`, 51 times in one second. ferry-cri had closed the whole connection, without restarting and without logging anything. Instrumenting swift-nio-http2 showed why:

```
h2 connection error reason=ENHANCE_YOUR_CALM misbehaving=true err=ExcessiveControlFrames
control frames 200: ping data=(2, 4, 16, 16, 9, 14, 7, 7): 198, settings: 1, settings ack: 1
```

- **The limit.** NIO's HTTP/2 flood protection allows 200 PING/SETTINGS/PRIORITY frames per 30 s on a connection. grpc-swift-nio-transport does not let you change that (checked through 2.10.0).
- **The pings.** 198 of every 200 were grpc-go's BDP pings, recognizable by their fixed payload. grpc-go sends one each time data arrives while none is outstanding. Over a Unix socket the RTT never justifies a bigger window, so it never stops.
- **How often.** A 20-pod burst passed the limit in under 30 s: 6 times in 4 cycles, and 10 times in about 25 minutes.
- **Why it hurts.** NIO closes a "misbehaving" connection with a GOAWAY whose last stream ID is 0: "none of your calls were processed". grpc-go therefore resent every call in flight, which is where StartContainer #2 came from. Calls it could not resend failed with the `Unavailable` above. Either way, ferry-cri was already running the original.

**The apparent fd leak was the same bug.** ferry-cri's open files were flat at 64 through every clean cycle. They jumped by about 180 only in cycles where pods crash-looped. Those are the orphaned first containers and their stdio.

## The fix

- **The limit.** `ferry-cri/vendor/grpc-swift-nio-transport` is 2.9.2 plus one new server setting, `http2.controlFrameRateLimit`. It is passed through to NIO's own `controlFrameRateLimit`. ferry-cri sets it to 10,000 per second. The socket is this user's and its only client is the kubelet. The limiter preallocates room for the whole count, which is why the limit is raised rather than removed. See `vendor/grpc-swift-nio-transport/FERRY.md`, including the SwiftPM identity warning this causes.
- **A duplicate StartContainer waits.** A second StartContainer for a container already being started now waits for that start to finish, instead of returning at once. That makes ferry-cri safe against the retry whatever causes it. On its own it fixed only half: one 20-cycle run with just this change still crash-looped 8 pods, from calls the kubelet could not resend.
- **Traces behind `FERRY_CRI_TRACE=1`.** StartContainer begin and end with a timestamp, a start that joins one already under way, and a stop that finds nothing running.

**Measured**, on the same Mac with the same workloads:

| | before | start fix only | both fixes |
|---|---|---|---|
| CRI connections cut | 6 in 4 cycles | not counted | **0 in 243** |
| `unexpected EOF` in the kubelet log | not counted | 87 in 32 cycles | **0** |
| failed steps | 3 of 12 scale-ups | 1 of 20 cycles (8 pods) | **0 of 243 cycles** |
| ferry-cri open files | 58 → 535 over 12 cycles | 64 → 256 over 20 | **58 → 79 over 243** |
| drain time | 3.2–7.1 s | 3.4–3.6 s | 3.2–3.6 s |

The 3-hour run is in `results/soak-3h/`.

## Still growing after the fix

The 3-hour run found two things that are not caused by this bug. Neither is fixed here.

- **ferry-cri's memory grows linearly: 47 → 694 MiB.** It rises about 1.6 MiB per cycle after warm-up, or roughly 27 KB per pod, and was still rising at the end. Nothing else did. Every other component levelled off, and the kubelet, etcd and the API server leveled off after an early climb.
- **Runtime files and logs grow.** Logs went 0 → 112 MiB (+0.5 MiB/cycle), and runtime files 101 → 313. Retained logs are hard links (`retainLog`), and they appear to outlive the containers they were kept for.

## What the harness got wrong along the way

- **Drain.** It first compared against a VM count taken at the start, before CoreDNS had booted, so every drain waited for a VM that was never going to leave. It now expects one VM per Running pod outside the soak namespace.
- **The CSV.** `say` wrote to stdout inside `drain()`, which is read through a command substitution, so log text ended up in the CSV.
- **Endpoints.** It judged the EndpointSlice on its first read, right after the rollout finished. It now allows 10 s of lag.
- **A failed scale-up.** It left 20 replicas behind. It now always scales back to 0.

## Not tried yet

These were not tried: sleep and wake, network changes, killing control-plane processes under load, and upgrades under load. `soak.sh` gives each of those a baseline to compare against.
