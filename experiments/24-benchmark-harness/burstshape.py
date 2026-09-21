import re, sys, datetime, statistics, collections
# A burst's wall time is the LAST pod, not the median one. So this reports the
# spread inside one burst: when each pod was admitted, when each reached Running,
# and which phase the stragglers spend their extra time in.
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
    if   "SyncLoop ADD" in l:                         pods[k].setdefault("admit", t)
    elif "All volumes are attached and mounted" in l: pods[k].setdefault("vols", t)
    elif "Creating PodSandbox for pod" in l:          pods[k].setdefault("sbx0", t)
    elif "Created PodSandbox for pod" in l:           pods[k].setdefault("sbx1", t)
    elif "Creating container in pod" in l:            pods[k].setdefault("ctr0", t)
    elif "Observed pod startup duration" in l:        pods[k].setdefault("done", t)

rows = [p for p in pods.values() if {"admit","done"} <= set(p)]
if len(rows) < 8:
    print(f"  only {len(rows)} traces"); sys.exit()
# group into bursts: pods admitted within 3s of each other
rows.sort(key=lambda p: p["admit"])
bursts, cur = [], [rows[0]]
for p in rows[1:]:
    if (p["admit"] - cur[-1]["admit"]).total_seconds() > 3:
        bursts.append(cur); cur = []
    cur.append(p)
bursts.append(cur)
bursts = [b for b in bursts if len(b) >= 15]
print(f"  bursts of >=15 pods: {len(bursts)}")
def d(p,a,b): return (p[b]-p[a]).total_seconds() if a in p and b in p else None
for i, b in enumerate(bursts):
    t0 = min(p["admit"] for p in b)
    fin = sorted((p["done"] - t0).total_seconds() for p in b)
    print(f"\n  burst {i+1}: {len(b)} pods, admit spread {(max(p['admit'] for p in b)-t0).total_seconds():.2f}s")
    print(f"    first Running +{fin[0]:.2f}s   median +{statistics.median(fin):.2f}s   LAST +{fin[-1]:.2f}s")
    # which phase do the last five spend their time in, vs the first five?
    b2 = sorted(b, key=lambda p: p["done"])
    for label, grp in (("first 5", b2[:5]), ("last 5", b2[-5:])):
        parts = []
        for a, c, nm in (("admit","vols","vol"), ("vols","sbx0","wait"),
                         ("sbx0","sbx1","sbx"), ("sbx1","ctr0","ctr"), ("ctr0","done","tail")):
            v = [d(p,a,c) for p in grp]; v = [x for x in v if x is not None]
            if v: parts.append(f"{nm} {statistics.median(v):.2f}")
        print(f"      {label}: " + "  ".join(parts))
