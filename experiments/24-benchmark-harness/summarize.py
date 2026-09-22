#!/usr/bin/env python3
"""raw.tsv -> the comparison tables.

Memory is reported on two bases, and each one is the same measurement for
every stack. That is a correction. This used to read ferry as the sum of its
processes' phys_footprint and kind and minikube as memory used inside Docker
Desktop's VM, on the reasoning that the cost does not live in the same place
for both -- which is true, and still printed the two in one column, where
1,485 next to 695 reads as "ferry costs twice what kind costs". Measured the
same way it is the other way round and not close: on the host basis a kind
cluster adds 2,455 MiB against mode 2's 1,184, before the 1,689 MiB of Docker
Desktop that has to be resident before the first pod.

- host phys_footprint, VMs plus that stack's own daemons. Whole-cluster for
  everything, and the row to compare. Its weakness is that it counts guest
  page cache, for ferry's node VM and Docker's VM alike.
- used inside the shared guest, where a stack has one. Narrower for ferry than
  the number suggests -- mode 2's guest holds the node and not the native
  control plane, and mode 1 has no shared guest -- so it is a supporting row,
  not the comparison.

Both are differences from a baseline, which only means anything if the
baseline was clean. Docker Desktop's VM keeps every page it has touched until
Docker itself restarts, so a Docker-based stack measured behind another reads
far too low; run.sh restarts Docker ahead of each one. ferry's baseline is a
measured zero.
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

# Host phys_footprint: the VM processes plus that stack's own host-side
# daemons. The same quantity for every stack -- Docker Desktop's VM and backend
# for kind and minikube, the pod/node VMs and the native control plane for
# ferry. This is the whole cluster in both cases, which is what makes it the
# row worth comparing.
def host_at(s, phase):
    vm, host = n(s, f"{phase}.vm_footprint"), n(s, f"{phase}.host_footprint")
    return None if vm is None or host is None else vm + host

def host_added(s, phase="idle"):
    a, b = host_at(s, phase), host_at(s, "baseline")
    return None if a is None or b is None else a - b

# A host-side delta is only a delta if the baseline was clean, and there is a
# cheap check for when it was not: a cluster that plainly appeared inside the
# guest cannot have cost the host nothing. Docker's VM keeps the pages a
# previous stack touched, so the second Docker stack in a battery subtracts
# almost all of its own cluster away -- minikube's published row is 10 MiB
# against 667 MiB of the same cluster visible inside the guest.
#
# Flagged rather than dropped, because the number is evidence of the bug and
# silently blanking it is how it survived a release in the first place.
def host_suspect(s):
    h, g = host_added(s), guest_added(s)
    return h is not None and g is not None and g > 100 and h < g

# The cell shows what is resident with the cluster up; the row under it shows
# how much of that was there beforehand, so the marginal cost is the
# subtraction and both readings are available without a third row. The warning
# is still decided on the subtraction, which is the part that can be wrong.
def host_cell(s):
    return fmt(host_at(s, "idle"), " MiB", 0) + (" ⚠" if host_suspect(s) else "")

# Used inside the one guest a stack shares, where it has one. Recorded for
# every stack now; mode 1 writes "-" because a pod per kernel has no such
# thing, and n() returns None for it.
def guest_at(s, phase):
    return n(s, f"{phase}.guest_used_mib")

def guest_added(s, phase="idle"):
    a = guest_at(s, phase)
    if a is None:
        return None
    # A missing baseline is zero, not unknown, when the guest did not exist
    # yet. kind and minikube read Docker Desktop's VM, which is up and holding
    # a few hundred MiB before any cluster, so theirs is a real subtraction.
    # Mode 2's guest is the node VM, which `ferry up` creates -- there is
    # nothing to read beforehand and the idle figure is already the cluster's
    # own. Subtracting an absent baseline blanked this cell for exactly the
    # stack the row exists to compare.
    b = guest_at(s, "baseline")
    return a - (b if b is not None else 0)

# Kept for the scaling tables below, which ask "how much did N pods add" of
# whichever basis a stack reports. Prefers the host row, since that is now
# populated for everything.
def mem_at(s, phase):
    v = host_at(s, phase)
    return v if v is not None else guest_at(s, phase)

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
    row("**idle memory**", host_cell),
    row("  ↳ of that, resident before any cluster",
        lambda s: fmt(host_at(s, "baseline"), " MiB", 0)),
    row("used inside the shared guest", lambda s: fmt(guest_added(s), " MiB", 0)),
    row("CPU, cluster down", lambda s: fmt(n(s, "baseline.cpu_core_pct"), "%", 1)),
    row("CPU, cluster up and empty", lambda s: fmt(n(s, "idle.cpu_core_pct"), "%", 1)),
], "**Idle memory is now the same measurement for every column.** It was not:\n"
   "the cell was `vm_footprint + host_footprint` for ferry and `used` inside\n"
   "Docker's VM for kind and minikube, printed side by side, which made ferry\n"
   "look about twice kind's cost when on either basis it is well under it. It is\n"
   "host phys_footprint throughout now -- that stack's VMs plus its own daemons,\n"
   "with the cluster up -- which is whole-cluster for all of them.\n\n"
   "The indented row is how much of that was already resident with no cluster,\n"
   "so the marginal cost of the cluster is the subtraction. Which of the two\n"
   "matters depends on whether Docker Desktop would be running anyway. ferry's\n"
   "is zero because its processes and VMs do not exist until `ferry up`.\n\n"
   "The guest row is narrower than it looks for ferry: kind and minikube put the\n"
   "entire cluster inside one guest, while mode 2's guest holds only the node,\n"
   "its control plane being native processes counted in the row above, and mode\n"
   "1 has no shared guest at all.\n\n"
   "The host row is only a subtraction if the baseline was clean. Docker\n"
   "Desktop's VM does not release pages when a cluster is deleted, so a\n"
   "Docker-based stack measured behind another one reads far too low -- `run.sh`\n"
   "restarts Docker before each of them for that reason. ferry's baseline is a\n"
   "real zero, because its VMs exit with the cluster. **A cell marked ⚠ added\n"
   "less to the host than it added inside the guest**, which cannot happen and\n"
   "means that stack's baseline was the previous one's leftovers.\n\n"
   "CPU is percent of one core, from cumulative CPU-time over a 60s window with\n"
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
