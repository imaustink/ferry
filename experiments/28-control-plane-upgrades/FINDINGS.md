# Experiment 28: control plane upgrades without an outage, and a live minor bump

**Question.** GAPS.md said three things about upgrades:

- there cannot be a zero-downtime control plane upgrade with one etcd and one API server;
- every node on a Mac moves together, because a checkout has one `bin/`;
- a minor bump on a running cluster had only been reasoned about.

Which of these is actually true?

**Method.** A private cluster from a worktree. `probe/` hits `/readyz` every 50 ms and counts failures and the longest outage; it counts slow requests separately from failed ones.

| script | what it does |
|---|---|
| `restart-control-plane.sh` | switches the control plane at the same version, with the probe running |
| `stop-timing.sh` | how long each process takes to exit on SIGTERM |
| `reuseport/` | how macOS spreads connections between two `SO_REUSEPORT` listeners |
| `service-after-proxyd-restart.sh` | how long a new Service takes to reach pods after ferry-proxyd restarts |
| `snapshot-state.sh`, `workload.yaml` | the state compared before and after an upgrade |

The full write-up is in [docs/UPGRADES.md](../../docs/UPGRADES.md), under "How the API server is replaced" and "A minor bump, on a running cluster".

## Two API servers cannot share a port on macOS

- With `SO_REUSEPORT`, macOS gives every new connection to the *oldest* listener: 200 of 200.
- The new API server's loopback client then dials the old server, fails its x509 checks, and the new server's post-start hooks die.
- **`--permit-port-sharing` does not give a handover here.**

Two properties of macOS binding do make one possible:

- An exact-address listener always beats a wildcard one.
- An IPv4 socket binds beside the `[::]` dual-stack wildcard with no socket options at all.

So `ferry-handover` binds every IPv4 address on the API port for the few seconds of the switch. While the old server stops and the new one starts, it holds each connection, then splices it through to `[::1]`. The Endpoints are written by `up.sh` (`--endpoint-reconciler-type=none`), so they never point anywhere else.

## Outage per control plane switch

Same version, 3 runs each, 50 ms probe:

| method | failed requests | longest outage |
|---|--:|--:|
| stop everything, start everything | 50–87 | 2.7–4.7 s |
| keep etcd running | 28–35 | 1.6–2.2 s |
| keep etcd running, with the handover | **0** | none; the slowest held request took 1.48 s |

Under load, one held request took about 2 s.

Stopping also got much faster:

- The API server took 60.2 s to exit on SIGTERM; `down.sh` killed it at 10 s.
- With `--shutdown-watch-termination-grace-period=2s` it exits in 1.15 s.
- `down.sh` went from 18.4 s to 1.3 s, and `ferry down` now takes 2.0 s.

## A live minor bump

On a two-node cluster, v1.34.0 → v1.35.8:

- **First apply:** 0 of 2969 `/readyz` probes failed. UIDs, pod names, IPs, restart counts and start times were identical afterwards, with 0 decode errors.
- **Second apply, after the fixes below:** 0 of 1472 in every series. An in-cluster client saw no failures.
- **Two kubelets on one Mac:** v1.34.0 and v1.35.8 ran side by side. The nodes were rolled forward, back and forward again.
- **Rollback:** a rollback with a restore refused connections for 2.8 s.
- **Next minor:** v1.35.8 → v1.36.4 was also applied live.
- **Recorded versions hold:** after a restart, node 0 came back at v1.35.8 while the cluster was at v1.36.4.

`tests/control-plane-minor-test.sh` walks the control plane alone from v1.34 to v1.37 and back down to v1.36. Every step had 0 failures and took 2.1–2.5 s.

## Found on the way

- **An etcd restore did not bump the revision**, so every watcher silently missed it: the revision went back from 1682 to 1338. Restores now use `--bump-revision 1e9 --mark-compacted`. The etcd-minor path had the same bug and had never been run.
- **After a restart, ferry-proxyd started counting its ruleset generations from zero again.** Guests long-polling for a newer generation waited out the full 25 s. A new Service reached its pods 28.5 s after a restart before the fix, and 3.3 s after it.
- **Two build seams never applied and cancelled each other out:** the `file_linux.go` widening and the `file_unsupported.go` retag. Making every seam fail loudly found them, and both are removed.

## Not verified

- The cluster-wide skew refusal has not been shown live; only the unit tests cover it.
- Nothing was taken through a minor on a second Mac.
- No minor whose etcd pairing changes was tried; every minor from v1.34 to v1.37 pairs with etcd v3.6.5.
- After a restore, CoreDNS came up at a pod address other than its reserved one, and stayed there until it was recreated.
