# Experiment 15: Is the control plane faster on the metal?

**Question.** [docs/MACHINES.md](../../docs/MACHINES.md) leaves one decision
open: whether ferry's control plane stays native Mach-O processes on the Mac, or
moves into a Linux VM like every other Kubernetes distribution. The intuition is
that native is faster to start and faster to run. This experiment measures it.

**Method.** Split the question into the parts that can actually differ.

Compute is not one of them: a hardware-virtualised guest runs CPU-bound work at
close to native speed, and the API server, controller manager and scheduler are
CPU and memory. What a VM changes is storage, and etcd is the one component
that cares, because every write goes through a WAL fsync before the API server
may answer. So:

- **Starting.** Time a whole native control plane from nothing to `/healthz`.
- **Running.** Run the same etcd 3.6.5, the same `etcdctl check perf --load=s`, on
  the metal as a darwin/arm64 process and inside a VM as linux/arm64.

The in-VM etcd runs in a pod VM through `ferry-cri`, on an ext4 backed by a file
on APFS. That is the storage path a control plane in a node VM would have.

Run on macOS 26.6.2, Apple M1 Max, 10 cores, 32 GiB.

## Results

### Starting: 4.66 seconds, native

```
PKI_SECONDS=0.60                  # once per cluster
START_TO_HEALTHZ_SECONDS=4.66     # etcd + apiserver + controller-manager + scheduler
```

The API server alone reports `Serving securely` 0.46s after it is executed,
and etcd is serving 60ms after it starts. Four processes, no image, no boot.

The VM side of this was not measured, because there is no node image yet, but
the comparison is nearly arithmetic. The same four processes, the same code, plus a
VM boot: 0.32s for a real pod VM today, more for a node image that has to start
containerd and a kubelet first. The startup difference is roughly one VM boot
against a 4.66s baseline, which is real but not a reason to decide anything.

### Running: the VM looks faster, and that is the problem

| | metal | in a VM |
|---|---|---|
| WAL fsync, mean | **5.103 ms** | **0.620 ms** |
| backend commit, mean | 18.052 ms | 1.707 ms |
| slowest request | 33.9 ms | 24.0 ms |
| stddev | 4.4 ms | 1.1 ms |
| throughput | 150 writes/s | 150 writes/s |

Both passed. 150 writes/s is the load `--load=s` asks for, not a ceiling either
one hit. The difference is latency, and the VM won it by 8x. That is the
opposite of the intuition and, on inspection, not a performance result at all.

### Why: the two sides are not doing the same work

Go's `os.File.Sync()` on darwin issues `F_FULLFSYNC`, which asks the drive to
flush its write cache and waits for it. Plain `fsync(2)` on macOS does not. It
pushes data to the device and returns. A guest's fsync becomes a virtio flush,
which the host honours according to the disk attachment's synchronization mode,
and Containerization's default for a disk image is `.fsync`, the weaker one.

Timed against the same file on the same filesystem:

| call | mean | worst |
|---|---|---|
| `os.File.Sync` → `F_FULLFSYNC`, what etcd does on darwin | **5.053 ms** | 39.1 ms |
| `syscall.Fsync` → plain `fsync(2)`, what the host does for a guest | **0.061 ms** | 2.58 ms |

Native etcd measured 5.103 ms against F_FULLFSYNC's 5.053 ms. The entire gap is
durability semantics, not virtualization.

Read the table the other way and the intuition is right after all. At *equal*
durability the metal is about 10x faster on the sync path: 0.061 ms for the
host's own weak fsync against 0.620 ms for the guest's. The difference is the
virtio round trip and the guest filesystem. A VM configured to be as durable as
the Mac (`synchronizationMode: .full`) would be slower than native, not faster.
The only way it wins is by promising less.

### Incidental: `ferry up` wastes a minute on every profile but the default

Timing the same start on profile-shifted ports:

| ports | start to `/healthz` |
|---|---|
| default (6443) | **4.66s** |
| shifted (any profile) | **63.41s** |

`control-plane/up.sh:134` polls `https://127.0.0.1:6443/livez` with the port
hardcoded, while everything around it uses `$API_PORT`. On a non-default profile
the probe can never succeed, so the loop runs all 60 iterations and the control
plane starts a minute later than it is ready. The fix is one variable:

```sh
 curl -sk --cert "$PKI_DIR/admin.crt" --key "$PKI_DIR/admin.key" \
-  https://127.0.0.1:6443/livez 2>/dev/null | grep -q ok && break
+  https://127.0.0.1:$API_PORT/livez 2>/dev/null | grep -q ok && break
```

Profiles exist so a second checkout can run its own cluster, so this bug hits
exactly the workflow profiles were built for. It is not fixed here, because
this experiment did not set out to change the control plane.

## What this means for the decision

- **Speed is not the argument.** At start, the metal saves about one VM boot out
  of 4.66 seconds. Running at dev-cluster scale, both sides met the same 150
  writes/s with the slowest request under 34 ms. Nothing here decides anything
  on performance grounds.
- **Durability is the argument, and it favours the metal.** On the Mac, etcd
  gets the strongest flush the hardware offers, because Go asks for it. In a VM
  it silently gets a weaker one unless the disk is configured otherwise. A
  control plane whose fsync does not reach stable storage can lose the last
  writes on a host crash.
- **So keep the control plane on Darwin.** It is simpler, it keeps a node image
  out of the critical path, and it is honest about durability. It is not
  faster.
- **The same hazard applies to mode 2.** Anything stateful in a node VM, such
  as a workload's database, or etcd if a cluster ever gets a control-plane
  machine, inherits `.fsync` by default. That is a deliberate choice to make,
  not a default to accept silently.

## Caveats

- **The in-VM side is a pod VM, not a node VM.** Same hypervisor, same kernel,
  same ext4-on-APFS storage path, but a node VM would run etcd under containerd
  with its own filesystem layout. The storage semantics are what is being
  measured and those are identical. The surrounding stack is not.
- **`--load=s` is a fixed-rate benchmark**, so throughput is the target rather
  than a maximum. It establishes that neither side struggles at that rate. It
  does not find either one's ceiling.
- **Compute was not measured.** The claim that a guest runs the API server's
  CPU work at near-native speed is standard for hardware virtualization but is
  assumed here, not demonstrated.
- **One machine, one run per cell.**

## Reproduce

```sh
./startup.sh                                   # native control plane, default ports
API_PORT=19443 ETCD_CLIENT_PORT=19379 ./startup.sh   # and on a shifted profile
./native.sh                                    # etcd on the metal
./in-vm.sh                                     # the same etcd in a VM
go run ./fsync                                 # F_FULLFSYNC against plain fsync
```

`startup.sh` needs the control-plane binaries in `bin/`. Symlinking them from a
built checkout is enough, `etcdctl` included. Without `etcdctl` the etcd
readiness loop burns its own 30 seconds, which is how the `/livez` bug above was
found.
