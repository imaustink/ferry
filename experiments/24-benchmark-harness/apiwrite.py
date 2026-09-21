#!/usr/bin/env python3
"""Sequential write latency to the API server, measured from inside a node.

The kubelet's status manager drains its queue from one goroutine, so what a
burst of twenty pods waits on is twenty *sequential* writes, not twenty
concurrent ones. That is the shape measured here: one PATCH at a time, on one
kept-alive connection, which is what client-go does.

Runs inside a pod on the node under test, because the point is the path the
kubelet actually uses. On ferry that is the guest crossing vmnet to an API
server running natively on the Mac; on kind it is a process talking to
another process in the same container.

Usage: apiwrite.py <base-url> <n>
Reads its credentials from the mounted serviceaccount.
"""
import json, ssl, statistics, sys, time, urllib.request

BASE = sys.argv[1].rstrip("/")
N = int(sys.argv[2]) if len(sys.argv) > 2 else 50
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
NS = open(f"{SA}/namespace").read().strip()
TOKEN = open(f"{SA}/token").read().strip()

# Unverified on purpose: this measures how long a write takes, and the
# certificate's SANs are not part of that. Hitting the node's own address
# rather than the service ClusterIP is the whole point, and that address is
# not always in the cert.
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

URL = f"{BASE}/api/v1/namespaces/{NS}/configmaps/apiwrite"
OPENER = urllib.request.build_opener(urllib.request.HTTPSHandler(context=CTX))


def patch(i):
    body = json.dumps({"data": {"n": str(i)}}).encode()
    req = urllib.request.Request(URL, data=body, method="PATCH")
    req.add_header("Authorization", f"Bearer {TOKEN}")
    req.add_header("Content-Type", "application/merge-patch+json")
    # One connection for the whole run, as client-go keeps one: otherwise this
    # measures TLS handshakes, which the kubelet does not pay per write.
    req.add_header("Connection", "keep-alive")
    t = time.monotonic()
    with OPENER.open(req, timeout=30) as r:
        r.read()
    return (time.monotonic() - t) * 1000


patch(0)  # warm: connection setup and TLS are not what this is counting
d = sorted(patch(i) for i in range(1, N + 1))
print(f"  {BASE}")
print(f"    {len(d)} sequential PATCHes   median {statistics.median(d):6.2f} ms"
      f"   min {d[0]:5.2f}   p90 {d[int(len(d) * 0.9)]:6.2f}   max {d[-1]:6.2f}")
print(f"    twenty of them would cost {statistics.median(d) * 20:.0f} ms")
