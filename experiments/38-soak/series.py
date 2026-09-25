#!/usr/bin/env python3
"""Prints chosen columns of one or more soaks' snapshots.csv, one row per column.

    series.py <column,column,...> snapshots.csv [snapshots.csv ...]
"""
import csv
import sys

cols = sys.argv[1].split(",")
for path in sys.argv[2:]:
    rows = list(csv.DictReader(open(path)))
    print(f"== {path} ({len(rows) - 1} cycles)")
    for c in cols:
        print(f"  {c:24} " + " ".join(r.get(c) or "?" for r in rows))
