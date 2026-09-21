import re, sys, datetime, collections, statistics
# Per pod: admit -> volumes mounted -> sandbox decision -> Running.
# Both kubelets log all of these at v=2, so kind and mode 2 are comparable
# without changing either one's verbosity.
#
# Which pods, as a regex on <namespace>/<name>. The default is the battery's
# own Deployment, which is what this was written against; burst.py names each
# round after a fresh uuid so that it cannot collide with the round before it,
# and those pods matched nothing at all here -- the script printed "no
# complete pod traces" and looked like a kubelet that had not logged rather
# than a filter that had not matched.
PODS = re.compile(sys.argv[1] if len(sys.argv) > 1 else r"bench-[\w-]+")

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
    if not t: continue
    m = re.search(r'pod="?([\w.-]+/[\w.-]+)"?', l) or re.search(r'pods=\["([\w.-]+/[\w.-]+)"\]', l)
    if not m: continue
    if not PODS.search(m.group(1)): continue
    k = m.group(1)
    if "SyncLoop ADD" in l:                      pods[k].setdefault("admit", t)
    elif "MountVolume.SetUp succeeded" in l:     pods[k]["vol"] = t
    elif "No sandbox for pod can be found" in l: pods[k].setdefault("sandbox", t)
    elif "Observed pod startup duration" in l:
        pods[k].setdefault("running", t)
        d = re.search(r"podStartSLOduration=([\d.]+)", l)
        if d: pods[k]["slo"] = float(d.group(1))

rows = [p for p in pods.values() if {"admit","sandbox","running"} <= set(p)]
if not rows:
    print("  no complete pod traces"); sys.exit()
def seg(a, b):
    v = [(p[b]-p[a]).total_seconds() for p in rows if a in p and b in p]
    return statistics.median(v) if v else None
def fmt(x): return "  —  " if x is None else f"{x:5.2f}s"
print(f"  pods traced                {len(rows)}")
print(f"  admit -> volumes mounted  {fmt(seg('admit','vol'))}")
print(f"  admit -> sandbox decision {fmt(seg('admit','sandbox'))}")
print(f"  sandbox decision -> Running {fmt(seg('sandbox','running'))}")
print(f"  admit -> Running (total)  {fmt(seg('admit','running'))}")
slo = [p["slo"] for p in rows if "slo" in p]
if slo: print(f"  kubelet podStartSLOduration median {statistics.median(slo):.3f}s")
