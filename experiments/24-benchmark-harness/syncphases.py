#!/usr/bin/env python3
"""Inside syncPod, from the kubelet's own --v=4 log.

phases.py splits a pod start into four coarse segments that both kubelets log
at v=2. That was enough to show the volume wait mattered and not enough to say
what the wait was made of -- whether the kubelet was doing work or waiting for
a turn.

At v=4 the volume manager narrates itself, and the two are separable:

  admit        SyncLoop ADD              the kubelet is told
  enter        SyncPod enter             the pod worker picks it up
  wait         volume_manager.go:434     "Waiting for volumes to attach"
  desired      desired_state_of_world..  the populator has noticed the volume
  verify       reconciler_common.go:251  VerifyControllerAttachedVolume
  mount        reconciler_common.go:225  MountVolume started
  mounted      operation_generator..     MountVolume.SetUp succeeded
  allmounted   volume_manager.go:495     "All volumes are attached and mounted"
  sandbox      kuberuntime_manager:1684  "Creating PodSandbox"
  sandboxed    kuberuntime_manager:1755  "Created PodSandbox"
  exit         SyncPod exit

mount -> mounted is the work: writing a projected token and renaming it into
place. Everything around it is the populator's 100ms loop and the reconciler's
100ms loop, which a pod joins wherever it happens to arrive. Reporting them
apart is the difference between "the volume is expensive" and "the volume is
cheap and the pod waits three ticks to be given it", which call for entirely
different fixes.

Split early/late across the burst because the question is what *stretches*: a
staircase and a flat burst can share a median.

Usage: syncphases.py [pod-regex] < kubelet.log
"""
import re, sys, datetime, collections, statistics

PODS = re.compile(sys.argv[1] if len(sys.argv) > 1 else r"burst/b[0-9a-f]{8}-")

# Matched in order; the first hit wins, so a substring of a later marker
# cannot steal it. setdefault everywhere: a pod is synced repeatedly after it
# is Running, and the second pass through syncPod would otherwise overwrite
# the timings of the first with a few microseconds of no-op.
MARKS = [
    ("admit",      '"SyncLoop ADD"'),
    ("enter",      '"SyncPod enter"'),
    ("wait",       "Waiting for volumes to attach and mount"),
    ("desired",    "Added volume to desired state"),
    ("verify",     "VerifyControllerAttachedVolume started"),
    ("mount",      "operationExecutor.MountVolume started"),
    ("mounted",    "MountVolume.SetUp succeeded"),
    ("allmounted", "All volumes are attached and mounted"),
    ("sandbox",    "Creating PodSandbox for pod"),
    ("sandboxed",  "Created PodSandbox for pod"),
    ("exit",       '"SyncPod exit"'),
]

# klog's own header, wherever it starts on the line.
#
# Anchored at the start this worked for ferry, whose kubelet writes klog
# straight to a file, and silently matched nothing for kind, whose kubelet is
# under systemd: journalctl puts "Sep 21 13:20:00 node kubelet[123]: " in
# front of every line, so the klog stamp is mid-line and every kind log
# parsed as zero timestamped lines. The output for that is "no complete pod
# traces", which reads like a kubelet that did not log what was wanted rather
# than a parser that could not see it.
KLOG = re.compile(r"[IWE](\d{4}) (\d\d:\d\d:\d\d\.\d+)")

def ts(l):
    m = KLOG.search(l)
    return datetime.datetime.strptime(m.group(2), "%H:%M:%S.%f") if m else None

pods = collections.defaultdict(dict)
for l in sys.stdin:
    t = ts(l)
    if not t:
        continue
    m = re.search(r'pod="?([\w.-]+/[\w.-]+)"?', l) or \
        re.search(r'pods=\["([\w.-]+/[\w.-]+)"\]', l)
    if not m or not PODS.search(m.group(1)):
        continue
    k = m.group(1)
    for name, needle in MARKS:
        if needle in l:
            pods[k].setdefault(name, t)
            break

# burst.py runs a warm-up round and then the measured ones, each under a
# fresh b<uuid> Deployment. Pooling them sorts one round's pods in among
# another's, and "early" and "late" then mean nothing at all -- the first
# version of this printed a flat staircase for that reason. Rounds are kept
# apart and the largest is reported, which is the one the burst is about.
rounds = collections.defaultdict(list)
for name, p in pods.items():
    if "admit" in p and "exit" in p:
        m = re.search(r"/(b[0-9a-f]{8})", name)
        rounds[m.group(1) if m else "?"].append(p)
if not rounds:
    print("  no complete pod traces (is the kubelet at --v=4?)")
    sys.exit()
# The most recent round, not the biggest one. burst.py's first round is a
# warm-up whose job is to pull the image, and on a node that does not have it
# yet that round's syncPod blocks on the pull -- 6.4s after creating the
# sandbox, on a kind cluster whose measured round finished all twenty pods in
# 897ms. Picking by size made that a coin toss between the two, and the warm
# round won it, which is how a 7-second median syncPod came to be printed for
# a stack that was not slow.
for v in rounds.values():
    v.sort(key=lambda p: p["admit"])
tag, rows = max(rounds.items(), key=lambda kv: kv[1][0]["admit"])
if len(rounds) > 1:
    print(f"  {len(rounds)} rounds in this log "
          f"({', '.join(f'{k}:{len(v)}' for k, v in rounds.items())}); "
          f"reporting the last, {tag}")

SEGS = [
    ("admit -> SyncPod enter",        "admit",      "enter"),
    ("enter -> waiting on volumes",   "enter",      "wait"),
    ("wait -> populator noticed",     "wait",       "desired"),
    ("populator -> verify attached",  "desired",    "verify"),
    ("verify -> mount started",       "verify",     "mount"),
    ("mount -> mounted  (the work)",  "mount",      "mounted"),
    ("mounted -> all mounted",        "mounted",    "allmounted"),
    ("all mounted -> create sandbox", "allmounted", "sandbox"),
    ("create -> sandbox created",     "sandbox",    "sandboxed"),
    ("sandbox created -> SyncPod exit", "sandboxed", "exit"),
    ("TOTAL admit -> SyncPod exit",   "admit",      "exit"),
]

def ms(rs, a, b):
    v = [(p[b] - p[a]).total_seconds() * 1000 for p in rs if a in p and b in p]
    return statistics.median(v) if v else None

def fmt(x):
    return "    —" if x is None else f"{x:5.0f}"

half = max(1, len(rows) // 2)
early, late = rows[:half], rows[-half:]
print(f"  {len(rows)} pods traced, by admit order; early = first {len(early)}, "
      f"late = last {len(late)}   (ms, median)")
print(f"  {'':34} {'all':>5} {'early':>6} {'late':>6}  {'late-early':>10}")
for label, a, b in SEGS:
    allv, e, l = ms(rows, a, b), ms(early, a, b), ms(late, a, b)
    d = "" if (e is None or l is None) else f"{l - e:+10.0f}"
    print(f"  {label:34} {fmt(allv)} {fmt(e):>6} {fmt(l):>6}  {d:>10}")

# The volume wait as a whole, against the part of it that is actual work --
# the ratio that says whether to make mounting faster or to stop waiting for
# a turn to do it.
w = ms(rows, "wait", "allmounted")
work = ms(rows, "mount", "mounted")
if w and work:
    print(f"\n  volume wait {w:.0f}ms, of which {work:.0f}ms is the mount itself "
          f"({work / w * 100:.0f}%)")

# When each pod reached each marker, measured from the first pod's admit.
#
# The segment table above says how long a pod takes once it is picked up; this
# says when it was picked up at all. They answer different halves of the same
# question, and only together do they distinguish a kubelet that is slow per
# pod from one that is fast per pod and starts them in waves -- which look
# identical from outside, in the only number the API can see.
print("\n  when each pod reached each marker, from the first pod's admit (ms)")
print(f"  {'':22} {'first':>6} {'median':>7} {'last':>6}  {'spread':>7}")
t0 = rows[0]["admit"]
for name, _ in MARKS:
    off = sorted((p[name] - t0).total_seconds() * 1000 for p in rows if name in p)
    if not off:
        continue
    print(f"  {name:22} {off[0]:6.0f} {statistics.median(off):7.0f} "
          f"{off[-1]:6.0f}  {off[-1] - off[0]:7.0f}")
