#!/usr/bin/env python3
"""Print what containerd logged during the biggest gap between RunPodSandbox
arrivals -- the stall that puts ferry's request spread at 427ms against kind's
64ms."""
import sys, re, datetime

path = sys.argv[1]
ts = re.compile(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)')
lines = []
for line in open(path, errors="replace"):
    m = ts.search(line)
    if m:
        lines.append((datetime.datetime.fromisoformat(m.group(1)), line.rstrip()))
lines.sort(key=lambda x: x[0])

arr = [(t, l) for t, l in lines if "RunPodSandbox for" in l]
if len(arr) < 2:
    print("not enough arrivals"); raise SystemExit(1)

gaps = [((arr[i+1][0] - arr[i][0]).total_seconds() * 1000, i) for i in range(len(arr) - 1)]
gaps.sort(reverse=True)
worst_ms, i = gaps[0]
t0, t1 = arr[i][0], arr[i+1][0]
print(f"biggest gap between requests: {worst_ms:.0f}ms\n")
print("everything containerd logged inside it:\n")
shown = 0
for t, l in lines:
    if t0 <= t <= t1:
        # Trim the timestamp and the level/id noise to keep it readable.
        body = re.sub(r'^.*?level=\w+\s+msg="?', '', l)[:150]
        print(f"  +{(t - t0).total_seconds()*1000:7.1f}ms  {body}")
        shown += 1
        if shown > 40:
            print("  ...")
            break
if shown <= 2:
    print("  (nothing -- containerd was idle for the whole gap)")
