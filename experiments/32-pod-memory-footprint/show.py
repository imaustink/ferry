#!/usr/bin/env python3
"""Prints what a probe script reported from inside the guest, from a result
file written by measure.sh.   show.py results/LABEL.json [regex]"""
import json, re, sys

d = json.load(open(sys.argv[1]))
pat = re.compile(sys.argv[2]) if len(sys.argv) > 2 else None
print(f"# footprint {d['footprint_mib']:.1f} MiB over {d['count']} VM(s), "
      f"{d['create_seconds']:.2f}s to running")
for line in d.get("logs") or []:
    if "P| " not in line:
        continue
    s = line.split("P| ", 1)[1]
    if pat is None or pat.search(s):
        print(s)
