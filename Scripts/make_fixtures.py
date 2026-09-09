"""Generates the DST test corpus and the golden decodes from the Python reference.

    python3 Scripts/make_fixtures.py

Requires pyembroidery (`pip install pyembroidery`). Rerunning is safe and deterministic.
"""
import hashlib
import json
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from reference_decoder import decode, canonical

import pyembroidery

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Packages", "StitchKit", "Tests", "StitchKitTests", "Fixtures",
)
os.makedirs(OUT, exist_ok=True)

# Full point lists are embedded for fixtures small enough to make a failure readable.
FULL_DUMP_LIMIT = 5000


def write(pattern, name):
    path = os.path.join(OUT, name)
    pyembroidery.write_dst(pattern, path)
    return path


def asymmetric():
    """An L with a hook on one arm. Nothing about it is symmetric in x or y, so a
    mirrored or flipped decode cannot pass. This fixture exists to catch the Y trap."""
    p = pyembroidery.EmbPattern()
    pts = []
    for y in range(0, 401, 10):        # tall arm, +Y
        pts.append((0, y))
    for x in range(0, 801, 10):        # long arm, +X, twice as long
        pts.append((x, 400))
    for y in range(400, 199, -10):     # short hook back up at the far end
        pts.append((800, y))
    for x in range(800, 599, -10):     # and inward
        pts.append((x, 200))
    for x, y in pts:
        p.add_stitch_absolute(pyembroidery.STITCH, x, y)
    p.end()
    return write(p, "asymmetric.dst")


def multicolor():
    """Six blocks, each a horizontal bar at a different height, so block splitting
    and per-block bounds are both checkable."""
    p = pyembroidery.EmbPattern()
    for block in range(6):
        y = block * 100
        for x in range(0, 501, 10):
            p.add_stitch_absolute(pyembroidery.STITCH, x, y)
        if block < 5:
            p.add_command(pyembroidery.COLOR_CHANGE)
    p.end()
    return write(p, "multicolor.dst")


def huge():
    """A dense spiral above 200k stitches, for the performance budget."""
    p = pyembroidery.EmbPattern()
    n = 220000
    for i in range(n):
        t = i * 0.004
        r = 5 + t * 1.9
        p.add_stitch_absolute(pyembroidery.STITCH, int(r * math.cos(t)), int(r * math.sin(t)))
    p.end()
    return write(p, "huge.dst")


def with_jumps_and_trims():
    """Separated islands, so the runs between them are jump-broken and long jump runs
    register as trims."""
    p = pyembroidery.EmbPattern()
    for island in range(4):
        ox = island * 400
        p.add_stitch_absolute(pyembroidery.JUMP, ox, 0)
        for x in range(0, 201, 10):
            p.add_stitch_absolute(pyembroidery.STITCH, ox + x, 0)
        for y in range(0, 201, 10):
            p.add_stitch_absolute(pyembroidery.STITCH, ox + 200, y)
        p.add_command(pyembroidery.TRIM)
    p.end()
    return write(p, "jumps.dst")


def derive_truncated(source):
    """A valid file with the last 40 bytes chopped off — the terminator goes with them."""
    data = open(source, "rb").read()[:-40]
    path = os.path.join(OUT, "truncated.dst")
    open(path, "wb").write(data)
    return path


def derive_garbage_header(source):
    """Valid body, header overwritten with random bytes."""
    data = bytearray(open(source, "rb").read())
    random.seed(20260909)
    data[:512] = bytes(random.randrange(256) for _ in range(512))
    path = os.path.join(OUT, "garbage-header.dst")
    open(path, "wb").write(bytes(data))
    return path


def empty():
    """A 512-byte header and nothing else."""
    header = (
        b"LA:empty           \r"
        b"ST:      0\rCO:  0\r+X:    0\r-X:    0\r+Y:    0\r-Y:    0\r"
        b"AX:+    0\rAY:+    0\rMX:+    0\rMY:+    0\rPD:******\r\x1a"
    )
    path = os.path.join(OUT, "empty.dst")
    open(path, "wb").write(header + b" " * (512 - len(header)))
    return path


def main():
    paths = [asymmetric(), multicolor(), huge(), with_jumps_and_trims()]
    paths.append(derive_truncated(paths[0]))
    paths.append(derive_garbage_header(paths[0]))
    paths.append(empty())

    goldens = {}
    for path in paths:
        name = os.path.basename(path)
        records = decode(path)
        blob = canonical(records)
        entry = {
            "recordCount": len(records),
            "sha256": hashlib.sha256(blob.encode()).hexdigest(),
        }
        if records:
            xs = [r[0] for r in records]
            ys = [r[1] for r in records]
            entry["minX"], entry["maxX"] = min(xs), max(xs)
            entry["minY"], entry["maxY"] = min(ys), max(ys)
            st = [r for r in records if r[2] == 0x03]
            entry["stitchCount"] = len(st)
            if st:
                entry["stitchMinX"] = min(r[0] for r in st)
                entry["stitchMaxX"] = max(r[0] for r in st)
                entry["stitchMinY"] = min(r[1] for r in st)
                entry["stitchMaxY"] = max(r[1] for r in st)
        if len(records) <= FULL_DUMP_LIMIT:
            entry["records"] = [list(r) for r in records]
        goldens[name] = entry
        print(f"{name:22} {len(records):>7} records  sha {entry['sha256'][:16]}  {os.path.getsize(path):>9} bytes")

    with open(os.path.join(OUT, "reference-decode.json"), "w") as f:
        json.dump(goldens, f, indent=2, sort_keys=True)
    print(f"\nwrote goldens -> {os.path.join(OUT, 'reference-decode.json')}")


if __name__ == "__main__":
    main()
