#!/usr/bin/env python3
"""Medians of the lines memory.sh, seq-cold.sh and probe-seq.sh print.
   summarize.py results/memory.txt ...   or   summarize.py results/seq-*.txt"""
import collections, re, statistics, sys

mem = collections.defaultdict(list)
seq = collections.defaultdict(list)
for path in sys.argv[1:]:
    for line in open(path):
        m = re.search(r"ra=(\d+) wl=(\w+) footprint ([\d.]+) start ([\d.]+)s", line)
        if m:
            mem[(m.group(2), int(m.group(1)))].append((float(m.group(3)), float(m.group(4))))
        m = re.search(r"pass=(\w+) ra=(\d+) bs=(\w+) .* ([\d.]+)([MG])B/s", line)
        if m:
            gbs = float(m.group(4)) * (1 if m.group(5) == "G" else 0.001)
            seq[(m.group(1), m.group(3), int(m.group(2)))].append(gbs)
for (wl, ra), xs in sorted(mem.items()):
    fp = [x[0] for x in xs]
    print(f"{wl:7} ra={ra:5}  footprint median {statistics.median(fp):6.1f} MiB/pod  "
          f"({' '.join(f'{x:.1f}' for x in fp)})  start {statistics.median(x[1] for x in xs):.2f}s")
for (kind, bs, ra), xs in sorted(seq.items()):
    print(f"{kind:6} bs={bs:6} ra={ra:5}  median {statistics.median(xs):5.1f} GB/s  "
          f"range {min(xs):.1f}-{max(xs):.1f}  n={len(xs)}")
