#!/usr/bin/env python3
"""raw.tsv -> the comparison tables.

Memory is not read the same way for every stack, because it does not live in
the same place. ferry's cost is native macOS processes plus one VM per pod, so
it is the sum of their phys_footprint. kind and minikube put the whole cluster
inside Docker Desktop's VM, where the honest number is the memory used inside
that guest -- its host-side RSS also carries guest page cache that accumulated
over the VM's 27 days of uptime and attributes to no cluster in particular.
"""
import collections, pathlib, statistics, sys

raw = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else
                   pathlib.Path(__file__).parent / "results/raw.tsv")
d = collections.defaultdict(dict)
for line in raw.read_text().splitlines():
    p = line.split("\t")
    if len(p) == 3:
        d[p[0]][p[1]] = p[2]

# The order columns appear in, and the only names this knows about. The
# relaxed variants are the same stacks with `--durability relaxed`, recorded
# under their own tag by the runner; without them here they sat in raw.tsv
# and never reached a table, which is a quiet way to lose half a comparison.
STACK_ORDER = ("ferry", "ferryrelaxed", "ferry2", "ferry2relaxed",
               "kind", "minikube")
LABELS = {"ferryrelaxed": "ferry, relaxed", "ferry2": "ferry, mode 2",
          "ferry2relaxed": "ferry, mode 2, relaxed"}
STACKS = [s for s in STACK_ORDER if s in d]

def n(s, k):
    try:    return float(d[s][k])
    except (KeyError, ValueError): return None

def fmt(v, suf="", nd=2):
    return "—" if v is None else f"{v:,.{nd}f}{suf}"

def row(label, fn):
    return f"| {label} | " + " | ".join(fn(s) for s in STACKS) + " |"

def table(title, rows, note=None):
    print(f"\n### {title}\n")
    print("| | " + " | ".join(LABELS.get(s, s) for s in STACKS) + " |")
    print("|:--" + "|--:" * len(STACKS) + "|")
    for r in rows: print(r)
    if note: print(f"\n{note}")

def sub(s, a, b):
    x, y = n(s, a), n(s, b)
    return None if x is None or y is None else x - y

# Memory a cluster adds, read where that stack actually keeps it.
def mem_at(s, phase):
    if s.startswith("ferry"):
        vm, host = n(s, f"{phase}.vm_footprint"), n(s, f"{phase}.host_footprint")
        return None if vm is None or host is None else vm + host
    return n(s, f"{phase}.guest_used_mib")

def mem_added(s, phase="idle"):
    a, b = mem_at(s, phase), mem_at(s, "baseline")
    return None if a is None or b is None else a - b

def per_pod(s, count):
    a, b = mem_at(s, f"scale{count}"), mem_at(s, "idle")
    return None if a is None or b is None else (a - b) / count

# -------------------------------------------------------------------------
print("## Results\n")
table("What each stack actually is", [
    row("Kubernetes", lambda s: d[s].get("k8s_version", "—")),
    row("control plane runs as", lambda s:
        "native macOS processes" if s.startswith("ferry") else "static pods in a container"),
    row("API server platform", lambda s: d[s].get("platform", "—")),
    row("a pod is", lambda s:
        "its own VM, own kernel" if s in ("ferry", "ferryrelaxed")
        else "a container on a shared kernel"),
    row("pods at rest", lambda s: d[s].get("idle_syspods", "—")),
    row("needs Docker Desktop", lambda s: "no" if s.startswith("ferry") else "yes"),
    # The row kind and minikube have no answer to. etcd inside Docker's VM
    # acknowledges a commit before it is on the drive; ferry at full
    # durability does not.
    row("writes survive power loss", lambda s:
        "no" if (s.endswith("relaxed") or not s.startswith("ferry")) else "yes"),
])

table("Cluster lifecycle", [
    row("first create (pulls artifacts)", lambda s: fmt(n(s, "create_cold_s"), "s")),
    row("create, artifacts cached", lambda s: fmt(n(s, "create_warm_s"), "s")),
    row("delete", lambda s: fmt(n(s, "delete_s"), "s")),
    row("disk once created", lambda s: fmt(n(s, "disk_mib"), " MiB", 0)),
],
"**The disk row is not a comparison.** ferry's is everything under FERRY_HOME,\n"
"including the node image it boots. kind's and minikube's is the node\n"
"container's writable layer only -- the ~1.3 GiB node image underneath it is a\n"
"Docker image shared with every other cluster that tool makes, and counting it\n"
"once per cluster would be as wrong as counting it zero times. Read each\n"
"column on its own.")

table("Idle — cluster up, nothing scheduled", [
    row("memory the cluster adds", lambda s: fmt(mem_added(s), " MiB", 0)),
    row("  ↳ measured as", lambda s:
        "VM + host footprint" if s.startswith("ferry") else "used in Docker's VM"),
    row("Docker Desktop host processes", lambda s:
        "n/a" if s.startswith("ferry") else fmt(n(s, "idle.host_footprint"), " MiB", 0)),
    row("CPU, cluster down", lambda s: fmt(n(s, "baseline.cpu_core_pct"), "%", 1)),
    row("CPU, cluster up and empty", lambda s: fmt(n(s, "idle.cpu_core_pct"), "%", 1)),
], "CPU is percent of one core, from cumulative CPU-time over a 60s window with\n"
   "the cluster left alone -- not `ps %cpu`, which is a decaying average over a\n"
   "window the kernel picks. This machine has 16 cores, so 100% is one of them.")

def lat(s):
    v = [n(s, f"pod_start_s.{i}") for i in range(1, 9)]
    return [x for x in v if x is not None]

table("Starting one pod — apply to Running, image cached", [
    row("median", lambda s: fmt(statistics.median(lat(s)) if lat(s) else None, "s")),
    row("min", lambda s: fmt(min(lat(s)) if lat(s) else None, "s")),
    row("max", lambda s: fmt(max(lat(s)) if lat(s) else None, "s")),
    row("first pull of alpine:3.20", lambda s: fmt(n(s, "warmup_pull_s"), "s")),
])

counts = sorted({int(k[5:-2]) for s in STACKS for k in d[s]
                 if k.startswith("scale") and k.endswith("_s") and k[5:-2].isdigit()})
rows = [row(f"{c} pods, time to all Running", lambda s, c=c: fmt(n(s, f"scale{c}_s"), "s"))
        for c in counts]
rows += [row(f"{c} pods, memory over idle", lambda s, c=c:
             fmt((lambda v: None if v is None else v * c)(per_pod(s, c)), " MiB", 0))
         for c in counts]
rows += [row(f"{c} pods, per pod", lambda s, c=c: fmt(per_pod(s, c), " MiB", 1))
         for c in counts]
table("Scaling out — alpine sleeping, no resource requests", rows,
      "**ferry2's memory rows are on the wrong basis.** They are the node VM's\n"
      "phys_footprint, which tracks guest page cache as much as pods — it read 7.3\n"
      "MiB/pod on one run and 140.7 on the next. Use `m2mem.sh`, which reads inside\n"
      "the guest the way kind is read. See docs/BENCHMARKING.md.")

# -------------------------------------------------------------------------
print("\n### Where the lines cross\n")
print("Memory as a function of pod count, fitted from idle and the 20-pod cell:\n")
for s in STACKS:
    base, slope = mem_added(s), per_pod(s, counts[-1]) if counts else None
    if base is None or slope is None: continue
    print(f"- **{s}**: {base:,.0f} MiB + {slope:,.1f} MiB per pod")
if len(STACKS) > 1 and "ferry" in STACKS:
    fb, fs = mem_added("ferry"), per_pod("ferry", counts[-1])
    for s in STACKS:
        if s == "ferry": continue
        ob, os_ = mem_added(s), per_pod(s, counts[-1])
        if None in (fb, fs, ob, os_) or fs == os_: continue
        x = (ob - fb) / (fs - os_)
        # Only the Docker-based stacks pay for Docker Desktop. ferry2 is a
        # ferry mode and needs it no more than ferry does; saying otherwise
        # was a formatting string that never checked which stack it was on.
        extra = ("" if s.startswith("ferry") else
                 ", before counting Docker Desktop itself, which only "
                 f"{s} needs")
        print(f"- ferry costs less than **{s}** below **{x:.1f} pods**, "
              f"more above{extra}.")
