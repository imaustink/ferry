#!/usr/bin/env python3
"""Where a single pod start actually spends its time, split at the API's own
transitions and stamped on one clock.

docs/BENCHMARKING.md records ferry winning every kubelet phase it controls
(volume 0.307s vs 0.306, sandbox 0.063 vs 0.065, container start 0.034 vs
0.045) while losing apply-to-Running by ~0.2s. So the gap is outside those
phases. This splits the whole interval into segments a host-side watcher can
see, which is enough to say *which* segment without ever comparing a host
timestamp to a guest one:

    apply -> object exists        the write path into etcd
    object -> spec.nodeName set   the scheduler
    nodeName -> status Running    delivery to the kubelet, its work, and the
                                  status write coming back

Every stamp is taken in this process, on the host clock, for both stacks, so a
host/guest clock offset cannot enter the result.

The watch goes through `kubectl proxy` rather than `kubectl get -w`: the latter
block-buffers its JSON into a pipe and the events do not arrive until long
after they happened. The proxy speaks newline-delimited JSON, handles each
stack's TLS and auth identically, and costs one local hop that both stacks pay.

Usage: timeline.py <kubeconfig> <nodeselector-key=value|-> [reps]
"""
import json, subprocess, sys, time, statistics, threading, uuid, urllib.request, socket

KC   = sys.argv[1]
SEL  = sys.argv[2]
REPS = int(sys.argv[3]) if len(sys.argv) > 3 else 5
NS   = "timeline"

def kubectl(*a):
    return subprocess.run(["kubectl", "--kubeconfig", KC, *a],
                          capture_output=True, text=True)

def now(): return time.monotonic()

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

PORT  = free_port()
proxy = subprocess.Popen(["kubectl", "--kubeconfig", KC, "proxy", "--port", str(PORT)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
BASE = f"http://127.0.0.1:{PORT}"

def wait_proxy():
    for _ in range(100):
        try:
            urllib.request.urlopen(f"{BASE}/healthz", timeout=1).read(); return True
        except Exception: time.sleep(0.1)
    return False

class Watcher(threading.Thread):
    """Stamps the first moment each transition is visible through the API."""
    daemon = True
    def __init__(self, name, rv):
        super().__init__()
        self.name_, self.rv, self.seen, self.stream = name, rv, {}, None
    def run(self):
        url = (f"{BASE}/api/v1/namespaces/{NS}/pods"
               f"?watch=1&resourceVersion={self.rv}&timeoutSeconds=180")
        try: self.stream = urllib.request.urlopen(url)
        except Exception: return
        for line in self.stream:
            if not line.strip(): continue
            try: ev = json.loads(line)
            except ValueError: continue
            obj = ev.get("object", {})
            if obj.get("metadata", {}).get("name") != self.name_: continue
            t = now()
            self.seen.setdefault("exists", t)
            if obj.get("spec", {}).get("nodeName"):
                self.seen.setdefault("scheduled", t)
            if obj.get("status", {}).get("phase") == "Running":
                self.seen.setdefault("running", t); return
    def stop(self):
        try:
            if self.stream: self.stream.close()
        except Exception: pass

MANIFEST = """apiVersion: v1
kind: Pod
metadata: {{name: {name}, namespace: {ns}}}
spec:
  terminationGracePeriodSeconds: 0
{sel}  containers:
  - name: c
    image: alpine:3.20
    command: ["sleep","3600"]
"""

def list_rv():
    with urllib.request.urlopen(f"{BASE}/api/v1/namespaces/{NS}/pods?limit=1") as r:
        return json.load(r)["metadata"]["resourceVersion"]

def one():
    name = f"tl-{uuid.uuid4().hex[:8]}"
    sel = "" if SEL == "-" else "  nodeSelector: {%s: %s}\n" % tuple(SEL.split("=", 1))
    y = MANIFEST.format(name=name, ns=NS, sel=sel)

    # Start watching from the version current *before* the apply, so the create
    # event cannot slip through between the list and the watch.
    w = Watcher(name, list_rv()); w.start()
    time.sleep(0.25)

    t0 = now()
    if subprocess.run(["kubectl", "--kubeconfig", KC, "apply", "-f", "-"],
                      input=y, capture_output=True, text=True).returncode:
        w.stop(); return None

    deadline = now() + 90
    while "running" not in w.seen and now() < deadline:
        time.sleep(0.002)
    w.stop()

    s, out = w.seen, None
    if "running" in s:
        ex  = s.get("exists", t0)
        sch = s.get("scheduled", ex)
        out = {"apply→exists":  (ex - t0) * 1000,
               "exists→sched":  (sch - ex) * 1000,
               "sched→Running": (s["running"] - sch) * 1000,
               "total":         (s["running"] - t0) * 1000}
    kubectl("-n", NS, "delete", "pod", name, "--wait=false", "--ignore-not-found")
    return out

try:
    if not wait_proxy():
        print("  kubectl proxy did not come up"); sys.exit(1)
    kubectl("create", "namespace", NS)
    one()                      # throwaway: caches the image, warms the namespace

    rows = [r for r in (one() for _ in range(REPS)) if r]
    if not rows:
        print("  no successful runs"); sys.exit(1)

    print(f"  n={len(rows)}   ms, median (min – max)")
    for k in ["apply→exists", "exists→sched", "sched→Running", "total"]:
        v = sorted(r[k] for r in rows)
        med = statistics.median(v)
        print(f"  {k:<15} {med:8.1f}   {v[0]:7.1f} – {v[-1]:<7.1f} {'█' * min(40, int(med/20))}")
finally:
    proxy.terminate()
