"""Diffs the Swift parser against the Python reference decoder over a directory of DST files.

    swift build -c release --package-path Packages/StitchKit
    python3 Scripts/crosscheck.py <directory-of-dst-files>

Reports any file where the two implementations disagree on a single record. Use it on real
files that are too private or too large to commit as fixtures.
"""
import glob
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from reference_decoder import decode, canonical

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUMP = os.path.join(ROOT, "Packages", "StitchKit", ".build", "release", "stitchdump")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if not os.path.exists(DUMP):
        sys.exit(f"build stitchdump first: swift build -c release --package-path Packages/StitchKit")

    files = sorted(glob.glob(os.path.join(sys.argv[1], "*.dst")))
    if not files:
        sys.exit(f"no .dst files under {sys.argv[1]}")

    failures = 0
    for path in files:
        expected = canonical(decode(path))
        actual = subprocess.run([DUMP, "records", path], capture_output=True, text=True).stdout
        name = os.path.basename(path)
        if expected == actual:
            print(f"  ok   {name:34} {expected.count(chr(10)):>7} records")
        else:
            failures += 1
            exp_lines, act_lines = expected.splitlines(), actual.splitlines()
            print(f"  FAIL {name:34} python {len(exp_lines)} vs swift {len(act_lines)} records")
            for i, (e, a) in enumerate(zip(exp_lines, act_lines)):
                if e != a:
                    print(f"       first divergence at record {i}: python {e!r} swift {a!r}")
                    break

    print(f"\n{len(files) - failures}/{len(files)} files match the reference decoder")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
