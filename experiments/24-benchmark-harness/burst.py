#!/usr/bin/env python3
"""Time to get N pods Running, watched rather than polled, and pinned.

Two corrections over the battery's scaleN_s:

  * It watches. The battery polls `kubectl get pods`, which costs 40-48ms an
    iteration, so its resolution is one iteration and every pod that turns
    Running mid-iteration waits for the next one.
  * It pins. The battery leaves ${NODE_SELECTOR} unset for ferry2, and with
    mode 2 on an unpinned pod lands on either node -- measured at an even 5/5
    split across the Mac node (a VM per pod) and the machine node (containers).
    Those rows are a mixture of the two architectures, not a measurement of
    either.

Reports the last pod, which is the wall time, and the spread inside the burst,
because a burst that finishes together and one that finishes in a staircase
can share a last-pod time.

Usage: burst.py <kubeconfig> <nodeselector-key=value|-> [replicas] [rounds]
"""
import json, os, subprocess, sys, time, statistics, threading, uuid, urllib.request, socket

KC    = sys.argv[1]
SEL   = sys.argv[2]
N     = int(sys.argv[3]) if len(sys.argv) > 3 else 20
ROUND = int(sys.argv[4]) if len(sys.argv) > 4 else 3
NS    = "burst"
# hostNetwork skips CNI ADD entirely. If the staircase is CNI being serialized,
# it collapses here; if it does not move, CNI is not the serializer.
HOSTNET = os.environ.get("HOSTNET") == "1"

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
    daemon = True
    def __init__(self, label, rv):
        super().__init__()
        self.label, self.rv = label, rv
        self.running, self.sched, self.created, self.nodes, self.stream = {}, {}, {}, {}, None
    def run(self):
        url = (f"{BASE}/api/v1/namespaces/{NS}/pods"
               f"?watch=1&resourceVersion={self.rv}&timeoutSeconds=300")
        try: self.stream = urllib.request.urlopen(url)
        except Exception: return
        for line in self.stream:
            if not line.strip(): continue
            try: ev = json.loads(line)
            except ValueError: continue
            o = ev.get("object", {})
            md = o.get("metadata", {})
            if md.get("labels", {}).get("app") != self.label: continue
            self.created.setdefault(md["name"], now())
            if o.get("spec", {}).get("nodeName"):
                self.sched.setdefault(md["name"], now())
            if o.get("status", {}).get("phase") == "Running":
                if md["name"] not in self.running:
                    self.running[md["name"]] = now()
                    self.nodes[md["name"]] = o.get("spec", {}).get("nodeName", "?")
                    if len(self.running) >= N: return
    def stop(self):
        try:
            if self.stream: self.stream.close()
        except Exception: pass

MANIFEST = """apiVersion: apps/v1
kind: Deployment
metadata: {{name: {name}, namespace: {ns}}}
spec:
  replicas: {n}
  selector: {{matchLabels: {{app: {name}}}}}
  template:
    metadata: {{labels: {{app: {name}}}}}
    spec:
      terminationGracePeriodSeconds: 0
{hn}{sel}      containers:
      - name: c
        image: alpine:3.20
        command: ["sleep","3600"]
"""

def list_rv():
    with urllib.request.urlopen(f"{BASE}/api/v1/namespaces/{NS}/pods?limit=1") as r:
        return json.load(r)["metadata"]["resourceVersion"]

def one():
    name = f"b{uuid.uuid4().hex[:8]}"
    sel = "" if SEL == "-" else "      nodeSelector: {%s: %s}\n" % tuple(SEL.split("=", 1))
    hn = "      hostNetwork: true\n" if HOSTNET else ""
    y = MANIFEST.format(name=name, ns=NS, n=N, sel=sel, hn=hn)

    w = Watcher(name, list_rv()); w.start()
    time.sleep(0.25)

    t0 = now()
    if subprocess.run(["kubectl", "--kubeconfig", KC, "apply", "-f", "-"],
                      input=y, capture_output=True, text=True).returncode:
        w.stop(); return None

    deadline = now() + 300
    while len(w.running) < N and now() < deadline:
        time.sleep(0.002)
    w.stop()

    out = None
    if len(w.running) >= N:
        run = sorted(t - t0 for t in w.running.values())
        cre = sorted(t - t0 for t in w.created.values())
        sch = sorted(t - t0 for t in w.sched.values())
        out = {"created_first": cre[0]*1000,  "created_last": cre[-1]*1000,
               "sched_first":   sch[0]*1000,  "sched_last":   sch[-1]*1000,
               "first": run[0]*1000, "median": statistics.median(run)*1000,
               "last": run[-1]*1000,
               "nodes": dict(sorted(
                   {n: list(w.nodes.values()).count(n) for n in set(w.nodes.values())}.items()))}
    kubectl("-n", NS, "delete", "deployment", name, "--wait=true", "--ignore-not-found")
    time.sleep(8)
    return out

try:
    if not wait_proxy():
        print("  kubectl proxy did not come up"); sys.exit(1)
    kubectl("create", "namespace", NS)
    one()                        # warm

    rows = [r for r in (one() for _ in range(ROUND)) if r]
    if not rows:
        print("  no successful rounds"); sys.exit(1)

    print(f"  {N} pods, {len(rows)} rounds{' , hostNetwork (no CNI)' if HOSTNET else ''}   ms")
    for k in ["created_first", "created_last", "sched_first", "sched_last",
              "first", "median", "last"]:
        v = sorted(r[k] for r in rows)
        print(f"  {k:<8} {statistics.median(v):8.0f}   {v[0]:7.0f} – {v[-1]:<7.0f}")
    print(f"  landed on: {rows[-1]['nodes']}")
finally:
    proxy.terminate()
