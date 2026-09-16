#!/usr/bin/env python3
"""Prints every result as one row: what it cost, and what each container cost."""
import glob
import json
import os
import sys

base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
rows = []
for path in sorted(glob.glob(os.path.join(base, "*.json"))):
    r = json.load(open(path))
    rows.append((os.path.basename(path)[:-5], r))

print(f"{'cell':36}{'n':>4}{'vms':>5}{'to run':>9}{'footprint':>11}{'per ctr':>9}")
for name, r in rows:
    n = r["count"]
    fp = r["footprint_mib"]
    print(f"{name:36}{n:>4}{r['peak']['vms']:>5}{r['create_seconds']:>8.2f}s"
          f"{fp:>11.0f}{fp / n:>9.1f}")

if "-v" in sys.argv:
    print()
    for name, r in rows:
        for line in r.get("logs") or []:
            print(f"{name}: {line}")
