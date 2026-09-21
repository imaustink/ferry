#!/usr/bin/env python3
"""Per pod: the kubelet decides phase=Running -> the API says so is stored.

Everything else here measures the kubelet doing work. This measures what
happens after it has finished: the status manager telling the API server, and
that being the thing a client watching the cluster actually waits for.

It exists because the two stopped agreeing. With the volume manager's poll
intervals shortened and the node disk's barrier relaxed, ferry's kubelet had
all twenty containers of a burst started in 516ms against kind's 706ms -- and
a client watching the API still saw ferry's last pod go Running 170ms *after*
kind's. Nothing inside syncPod could account for that, because by then ferry
was winning inside syncPod.

The status manager drains its queue from one goroutine, so these are serial:
a per-write cost that is invisible on one pod shows up multiplied by twenty
on a burst, and shows up as a staircase rather than a constant, which is the
signature to look for in the first-half/last-half split below.

Usage: statuslat.py [pod-regex] < kubelet.log
"""
import re, sys, datetime, collections, statistics

PODS = re.compile(sys.argv[1] if len(sys.argv) > 1 else r"burst/b[0-9a-f]{8}-")
# Matched mid-line: kind's kubelet is under systemd and journalctl puts its
# own prefix in front of klog's. See phases.py.
KLOG = re.compile(r"[IWE](\d{4}) (\d\d:\d\d:\d\d\.\d+)")


def ts(l):
    m = KLOG.search(l)
    return datetime.datetime.strptime(m.group(2), "%H:%M:%S.%f") if m else None


# The first transition into Running, and the first stored status after it.
# Both guarded: a pod is re-synced for as long as it exists and writes its
# status again every time, so without "first after Running" this measures
# some later no-op update instead.
run, stored, order = {}, {}, []
for l in sys.stdin:
    t = ts(l)
    if not t:
        continue
    m = re.search(r'pod="([\w.-]+/[\w.-]+)"', l)
    if not m or not PODS.search(m.group(1)):
        continue
    k = m.group(1)
    if 'oldPhase="Pending" phase="Running"' in l:
        if k not in run:
            run[k], _ = t, order.append(k)
    elif '"Status for pod updated successfully"' in l and k in run and k not in stored:
        stored[k] = t

# By round, for the same reason syncphases.py does it: burst.py's warm-up
# round would otherwise be averaged in with the measured one.
rounds = collections.defaultdict(list)
for k in order:
    if k in stored:
        m = re.search(r"/(b[0-9a-f]{8})", k)
        rounds[m.group(1) if m else "?"].append((run[k], stored[k]))
if not rounds:
    print("  no pod reached Running in this log")
    sys.exit()
for v in rounds.values():
    v.sort()
tag, rows = max(rounds.items(), key=lambda kv: kv[1][0][0])

d = sorted((s - r).total_seconds() * 1000 for r, s in rows)
half = max(1, len(d) // 2)
print(f"  round {tag}, {len(rows)} pods")
print(f"  phase=Running -> status stored   median {statistics.median(d):5.0f} ms"
      f"   min {d[0]:.0f}  max {d[-1]:.0f}")
print(f"    first half {statistics.median(d[:half]):.0f} ms,"
      f" last half {statistics.median(d[half:]):.0f} ms"
      f"   (a staircase here means the writes are queueing)")
t0 = min(r for r, _ in rows)
print(f"  all {len(rows)} Running at the kubelet within "
      f"{(max(r for r, _ in rows) - t0).total_seconds() * 1000:.0f} ms,"
      f" all stored within {(max(s for _, s in rows) - t0).total_seconds() * 1000:.0f} ms")
