#!/bin/bash
# G2's cold-load clause, measured as a distribution rather than a single sample.
#
# The harness measures process start -> ready, so one route needs one process and the number
# cannot be repeated inside a run. It also spreads 534-1072 ms across runs, dominated by
# WebKit's web-content process spawn, so a single sample near the 1000 ms budget is a coin
# flip and its pass/fail says more about the machine's mood than about the editor.
#
# Two conditions matter and are enforced here rather than left to the operator:
#   - a WARM binary. The first run after a link pays page-cache cost on a newly written
#     executable carrying a 13 MB resource bundle: ~467 ms to the first trace line against
#     ~47 ms warm. So one discarded warm-up run precedes the sample.
#   - a QUIET machine. Building or testing in parallel moves the median substantially.
#
# usage: measure-cold-load.sh [runs] [scheme|blob|file]
set -euo pipefail
runs="${1:-12}"
route="${2:-scheme}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
binary="$root/.build/release/S3Harness"

if [[ ! -x "$binary" ]]; then
    echo "build it first:  swift build -c release --package-path $root --product S3Harness" >&2
    exit 1
fi

"$binary" --route "$route" --frames 30 >/dev/null 2>&1 || true   # warm-up, discarded

for _ in $(seq 1 "$runs"); do
    "$binary" --route "$route" --frames 30 2>/dev/null \
        | python3 -c 'import json,sys; c=json.load(sys.stdin)["coldLoad"]; print(c["processStartToReadyMs"], c["navigationStartToReadyMs"])'
done | python3 -c '
import statistics as s, sys
rows = [tuple(map(float, line.split())) for line in sys.stdin if line.strip()]
for label, values in (("process start -> ready", [r[0] for r in rows]),
                      ("navigation    -> ready", [r[1] for r in rows])):
    inside = sum(1 for v in values if v < 1000)
    print(f"{label}: median {s.median(values):.0f} ms  range {min(values):.0f}-{max(values):.0f}  "
          f"within 1000 ms budget: {inside}/{len(values)}")
'
