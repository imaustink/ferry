#!/usr/bin/env python3
"""The tables in FINDINGS.md, out of results/raw.tsv.

Cells are appended, never replaced, so a tag re-run twice appears twice. The
last value wins, which is the one the findings quote -- with the exception of
`failed`, which is dropped rather than allowed to overwrite a good reading from
an earlier run of the same cell.
"""
import sys
from pathlib import Path

RAW = Path(__file__).parent / "results" / "raw.tsv"

STACKS = [
    ("ferry", "ferry (2 cpu, 512 MiB)"),
    ("ferry-sized", "ferry (8 cpu, 4 GiB)"),
    ("docker", "Docker Desktop"),
    ("colima", "colima"),
]
WORKLOADS = ["tiny", "node", "fat"]
PHASES = [
    ("cold-build", "cold build"),
    ("cold-export", "export"),
    ("cold-load", "load"),
    ("incr-build", "incremental build"),
    ("incr-export", "export"),
    ("incr-load", "load"),
    ("noop", "no-op rebuild"),
]


def load():
    values = {}
    for line in RAW.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        tag, key, value = parts
        if value == "failed":
            continue
        values[(tag, key)] = value
    return values


def num(values, tag, key):
    v = values.get((tag, key))
    if v is None:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def table(values, workload):
    print(f"\n### {workload}\n")
    head = "| | " + " | ".join(label for _, label in STACKS) + " |"
    print(head)
    print("|:--|" + "--:|" * len(STACKS))
    for key, label in PHASES:
        cells = []
        for stack, _ in STACKS:
            v = num(values, f"{stack}-{workload}", key)
            cells.append("—" if v is None else f"{v/1000:.2f} s")
        print(f"| {label} | " + " | ".join(cells) + " |")
    # The three that make up the loop, added up, because that is what a person
    # waiting at a terminal actually experiences.
    for prefix, label in (("cold", "**cold, end to end**"), ("incr", "**incremental, end to end**")):
        cells = []
        for stack, _ in STACKS:
            parts = [num(values, f"{stack}-{workload}", f"{prefix}-{p}")
                     for p in ("build", "export", "load")]
            cells.append("—" if any(p is None for p in parts) else f"{sum(parts)/1000:.2f} s")
        print(f"| {label} | " + " | ".join(cells) + " |")


def main():
    values = load()
    for workload in WORKLOADS:
        table(values, workload)

    print("\n### What it costs to keep a builder available\n")
    print("| | host MiB | in-guest MiB |")
    print("|:--|--:|--:|")
    for tag, label in (("ferry-buildkit-pod", "ferry, a buildkitd pod"),
                       ("docker-desktop-vm", "Docker Desktop's VM"),
                       ("colima-vm", "colima's VM")):
        host = values.get(("cost", f"{tag}-host"), "—")
        guest = values.get(("cost", f"{tag}-guest"), "—")
        print(f"| {label} | {host} | {guest} |")


if __name__ == "__main__":
    sys.exit(main())
