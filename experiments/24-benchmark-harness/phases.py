import re, sys, datetime, collections, statistics
# Per pod: admit -> volumes mounted -> sandbox decision -> Running.
# Both kubelets log all of these at v=2, so kind and mode 2 are comparable
# without changing either one's verbosity.
def ts(l):
    m = re.match(r"[IWE]\d{4} (\d\d:\d\d:\d\d\.\d+)", l)
    return datetime.datetime.strptime(m.group(1), "%H:%M:%S.%f") if m else None

pods = collections.defaultdict(dict)
for l in sys.stdin:
    t = ts(l)
    if not t: continue
    m = re.search(r'pod="?([\w.-]+/bench-[\w-]+)"?', l) or re.search(r'pods=\["([\w.-]+/bench-[\w-]+)"\]', l)
    if not m: continue
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
