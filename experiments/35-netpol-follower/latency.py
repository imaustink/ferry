#!/usr/bin/env python3
"""How long a NetworkPolicy takes to reach a joined node's pod and its edge.

usage: latency.py <client-pod> <web-ip> <hostport> [trials]
with KUBECONFIG pointing at the cluster, e34web and e34cli running (policy.sh
leaves them for this when KEEP=1).

Each trial applies a friends-only policy to e34web and times, on the Mac's
clock, from just before `kubectl apply` until

  pod   a wget from e34cli (on the other node) to e34web stops answering
  edge  a connection to 127.0.0.1:<hostport> on the Mac is refused

then deletes the policy and times until both answer again. The pod probes run
down one `kubectl exec` session, so each costs a round trip through the
streamer rather than a process start. A probe of a blocked pod waits out
wget's one-second timeout, so the pod figure for removal is good to a second;
the others are good to a probe interval, a few tens of milliseconds.
"""
import socket
import statistics
import subprocess
import sys
import threading
import time

cli, ip, hostport = sys.argv[1], sys.argv[2], int(sys.argv[3])
trials = int(sys.argv[4]) if len(sys.argv) > 4 else 5

POLICY = """apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: e35-friends-only}
spec:
  podSelector: {matchLabels: {app: e34web}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {role: e35-nobody}}}]
"""

shell = subprocess.Popen(["kubectl", "exec", "-i", cli, "--", "sh"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
lock = threading.Lock()


def pod_ok():
    with lock:
        shell.stdin.write(f"wget -q -T 1 -O - http://{ip}/ >/dev/null 2>&1 && echo ok || echo no\n")
        shell.stdin.flush()
        return shell.stdout.readline().strip() == "ok"


def edge_ok():
    try:
        with socket.create_connection(("127.0.0.1", hostport), timeout=0.5) as s:
            s.sendall(b"GET / HTTP/1.0\r\n\r\n")
            return b"hello" in s.recv(4096)
    except OSError:
        return False


def until(probe, want, start, limit=30):
    while time.time() - start < limit:
        sent = time.time()
        if probe() == want:
            return sent - start
        time.sleep(0.02)
    return float("nan")


def kubectl(*args, stdin=None):
    subprocess.run(["kubectl", *args], input=stdin, text=True, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


subprocess.run(["kubectl", "delete", "networkpolicy", "e35-friends-only", "--ignore-not-found"],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
results = {"apply pod": [], "apply edge": [], "remove pod": [], "remove edge": []}
for n in range(trials):
    now = time.time()
    until(pod_ok, True, now)
    until(edge_ok, True, now)
    time.sleep(1)
    for phase, args, stdin, want in (("apply", ["apply", "-f", "-"], POLICY, False),
                                     ("remove", ["delete", "networkpolicy", "e35-friends-only"], None, True)):
        start = time.time()
        kubectl(*args, stdin=stdin)
        got = {}
        threads = [threading.Thread(target=lambda k=k, p=p: got.__setitem__(k, until(p, want, start)))
                   for k, p in (("pod", pod_ok), ("edge", edge_ok))]
        [t.start() for t in threads]
        [t.join() for t in threads]
        results[f"{phase} pod"].append(got["pod"])
        results[f"{phase} edge"].append(got["edge"])
        print(f"  trial {n + 1} {phase:6s}: pod {got['pod'] * 1000:6.0f} ms   edge {got['edge'] * 1000:6.0f} ms",
              flush=True)
        time.sleep(1)

for key, values in results.items():
    ms = sorted(v * 1000 for v in values)
    print(f"{key:12s} median {statistics.median(ms):6.0f} ms   min {ms[0]:6.0f}   max {ms[-1]:6.0f}")
shell.stdin.close()
