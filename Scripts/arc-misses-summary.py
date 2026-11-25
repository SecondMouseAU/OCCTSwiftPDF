#!/usr/bin/env python3
"""Summarise the tables `pdfprobe arc-misses` writes.

    arc-misses-summary.py misses <misses.tsv> [<misses-after.tsv>]
    arc-misses-summary.py bands <fits.tsv>

`misses` sorts the reference arcs no fit matched by what the page draws along them, and by whether
the writer's coordinate grid leaves the arc enough radius to be read at all (the noise floor: a
paper radius under 20 grid steps). With two files it shows both side by side. `bands` gives, for
fits of curves and of chords, how many lie in each sweep band and how many of them a reference arc
confirms. The figures in the experiment page (okf/experiments/option-1-spike.md) come from these.

Standard library only.
"""

import collections
import csv
import sys

# The writers' coordinate grids on the paper, in millimetres: Acrobat PDFWriter rounds to 0.1 point,
# Acrobat Distiller to 1/1200 inch. A producer not listed is taken to have none.
GRID = {"Acrobat PDFWriter": 0.0353, "Acrobat Distiller": 0.0212}
NOISE_STEPS = 20

FORMS = [
    "nothing (not printed, or another version)",
    "curves that lie on the circle",
    "8 or more chords that lie on it",
    "fewer than 8 chords",
    "curves and chords",
    "geometry along it, not wholly on the circle",
]


def read(path):
    with open(path, newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def form(row):
    support = float(row["support"])
    covered = float(row["covered"])
    curves = int(row["curves"])
    lines = int(row["lines"])
    run = int(row["run"])
    if support < 0.5:
        return 0
    if covered >= 0.8:
        if curves and not lines:
            return 1
        if lines and not curves:
            return 2 if run >= 8 else 3
        return 4
    return 5


def below_noise(row):
    return float(row["radius"]) < NOISE_STEPS * GRID.get(row["producer"], 0.0)


def misses(paths):
    tables = [read(path) for path in paths]
    print(f"unmatched reference circles and arcs: {', '.join(str(len(t)) for t in tables)}")
    for path, table in zip(paths, tables):
        under = sum(1 for r in table if float(r["sweep"]) < 45 and r["shape"] == "arc")
        noisy = sum(1 for r in table if below_noise(r))
        print(f"  {path}: {under} sweep under 45 degrees, {noisy} below the noise floor")
    head = ["what the page has along the arc"] + [f"all {i + 1}" for i in range(len(tables))]
    print("\n| " + " | ".join(head) + " | above the noise floor, last |")
    print("|---|" + "---|" * (len(tables) + 1))
    counts = [collections.Counter(form(r) for r in t) for t in tables]
    last = collections.Counter(form(r) for r in tables[-1] if not below_noise(r))
    for index, name in enumerate(FORMS):
        cells = " | ".join(f"{c[index]:,}" for c in counts)
        print(f"| {name} | {cells} | {last[index]:,} |")
    print(f"| total | {' | '.join(f'{len(t):,}' for t in tables)} | {sum(last.values()):,} |")


def bands(path):
    rows = read(path)
    edges = [(8, 12), (12, 15), (15, 20), (20, 25), (25, 30), (30, 35), (35, 45), (45, 90), (90, 361)]
    print(f"{len(rows)} fits; matched = a reference circle or arc within the bound `arc-misses` used")
    for kind in ("curves", "lines", "mixed"):
        print(f"\narcs from {kind}")
        for low, high in edges:
            sub = [
                r
                for r in rows
                if r["shape"] == "arc" and r["input"] == kind and low <= float(r["sweep"]) < high
            ]
            if not sub:
                continue
            hit = sum(1 for r in sub if r["matched"] in ("1", "2"))
            print(f"  {low:>3}-{high - 1 if high == 361 else high:<3} {len(sub):8,} fits  {100 * hit / len(sub):5.1f}% matched")


def main(argv):
    if len(argv) >= 3 and argv[1] == "misses":
        misses(argv[2:4])
    elif len(argv) == 3 and argv[1] == "bands":
        bands(argv[2])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
