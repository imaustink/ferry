#!/usr/bin/env python3
"""Reads a soak's snapshots.csv and says which counts did not come back.

    report.py snapshots.csv

Row 0 is the baseline, taken before any churn. For every numeric column it
prints the baseline, the last value, the change, and the slope per cycle over
the second half of the run -- the first cycles warm caches and fill pools, and
a real leak is the part that keeps growing after that. A column is flagged when
its second-half slope would add a meaningful amount over 100 cycles.
"""
import csv
import sys

# How much growth over 100 cycles is worth a flag, by kind of column.
# Anything not matched uses DEFAULT.
THRESHOLDS = [
    ("_fds", 20), ("_threads", 10), ("_rss_mib", 50), ("vms", 1),
    ("run_files", 10), ("run_sockets", 5), ("run_dirs", 5), ("run_mib", 200),
    ("run_logs_mib", 100), ("state_mib", 200), ("etcd_db_mib", 100),
    ("if_", 1), ("tcp_", 10), ("udp", 10), ("unix_socks", 10),
    ("k8s_pods", 1), ("k8s_endpoints", 1),
]
DEFAULT = 50
SKIP = {"cycle", "t", "drain_s", "failures", "host_used_mib", "k8s_events"}


def threshold(col):
    for suffix, v in THRESHOLDS:
        if suffix in col:
            return v
    return DEFAULT


def slope(ys):
    n = len(ys)
    if n < 2:
        return 0.0
    xs = range(n)
    mx, my = sum(xs) / n, sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else 0.0


def num(v):
    try:
        return float(v)
    except ValueError:
        return None


def main(path):
    rows = list(csv.DictReader(open(path)))
    if len(rows) < 2:
        print("fewer than two snapshots; nothing to compare")
        return
    base, last = rows[0], rows[-1]
    cycles = len(rows) - 1
    fails = sum(int(r["failures"]) for r in rows[1:])
    drains = [num(r["drain_s"]) for r in rows[1:]]
    timeouts = sum(1 for d in drains if d is None)
    done = [d for d in drains if d is not None]
    print(f"{cycles} cycles, {fails} failed steps, {timeouts} drain timeouts")
    if done:
        print(f"drain: first {done[0]:.1f}s  last {done[-1]:.1f}s  max {max(done):.1f}s")
    half = rows[len(rows) // 2:]
    flagged, steady = [], []
    for col in rows[0].keys():
        if col in SKIP or col.endswith("_up"):
            continue
        ys = [num(r.get(col, "")) for r in half]
        if any(y is None for y in ys) or num(base.get(col, "")) is None:
            continue
        b, l = num(base[col]), num(last[col])
        s = slope(ys)
        line = f"  {col:32} {b:>8.0f} -> {l:>8.0f}  ({l - b:+.0f}, {s:+.2f}/cycle)"
        (flagged if s * 100 >= threshold(col) else steady).append(line)
    downs = [c for c in rows[0] if c.endswith("_up") and last.get(c) != base.get(c)]
    if downs:
        print("components that changed state: " + ", ".join(f"{c}={base[c]}->{last[c]}" for c in downs))
    print("\nstill growing in the second half:" if flagged else "\nnothing still growing in the second half")
    print("\n".join(flagged))
    print("\nsteady:")
    print("\n".join(steady))
    print(f"\nhost memory in use (Mac-wide, noisy): {base['host_used_mib']} -> {last['host_used_mib']} MiB")


if __name__ == "__main__":
    main(sys.argv[1])
