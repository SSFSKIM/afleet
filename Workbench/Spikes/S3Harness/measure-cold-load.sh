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
# A run that is SLOW is a measurement; a run that did not measure is a failure. The harness
# exits 5 when every load path is carried and the cold load is over the 1000 ms budget — the
# very sample this distribution exists to place — so status 5 is collected like status 0, and
# only a run that produced no valid reading (a crash, a route that drops a load path, a binary
# that never reaches `ready`) is counted against the script. Before this the loop ran under
# `set -e` and died on the first over-budget sample, which truncated the distribution at exactly
# the observation that mattered; every run so far happened to be under budget, so nothing said so.
#
# usage: measure-cold-load.sh [runs] [scheme|blob|file]
#        S3HARNESS_BIN=<path> overrides the binary, which is how the over-budget path is tested.
set -euo pipefail
runs="${1:-12}"
route="${2:-scheme}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
binary="${S3HARNESS_BIN:-$root/.build/release/S3Harness}"

if [[ ! -x "$binary" ]]; then
    echo "build it first:  swift build -c release --package-path $root --product S3Harness" >&2
    exit 1
fi

# Reads one run's JSON report and prints the two cold-load numbers. Exits non-zero when the
# report is not a measurement, whatever the harness's own status said.
read_sample() {
    python3 -c '
import json, sys
try:
    cold = json.load(sys.stdin)["coldLoad"]
except Exception as failure:
    print("unreadable report: %s" % failure, file=sys.stderr)
    raise SystemExit(1)
if not cold.get("reachedReady"):
    print("the run never reached ready", file=sys.stderr)
    raise SystemExit(1)
print(cold["processStartToReadyMs"], cold["navigationStartToReadyMs"])
'
}

"$binary" --route "$route" --frames 30 >/dev/null 2>&1 || true   # warm-up, discarded

samples=""
failed=0
for index in $(seq 1 "$runs"); do
    report=""
    status=0
    report="$("$binary" --route "$route" --frames 30 2>/dev/null)" || status=$?
    case "$status" in
        0|5) ;;   # 0: measured, within budget.  5: measured, over budget. Both are observations.
        *)  echo "run $index: S3Harness exited $status — not a measurement" >&2
            failed=$((failed + 1))
            continue ;;
    esac
    if sample="$(printf '%s' "$report" | read_sample)"; then
        samples="$samples$sample"$'\n'
    else
        echo "run $index: exited $status but reported no cold-load measurement" >&2
        failed=$((failed + 1))
    fi
done

printf '%s' "$samples" | python3 -c '
import statistics as s, sys
rows = [tuple(map(float, line.split())) for line in sys.stdin if line.strip()]
if not rows:
    print("no observations were collected", file=sys.stderr)
    raise SystemExit(1)
for label, values in (("process start -> ready", [r[0] for r in rows]),
                      ("navigation    -> ready", [r[1] for r in rows])):
    inside = sum(1 for v in values if v < 1000)
    print(f"{label}: median {s.median(values):.0f} ms  range {min(values):.0f}-{max(values):.0f}  "
          f"within 1000 ms budget: {inside}/{len(values)}")
print(f"observations: {len(rows)}")
'

if (( failed > 0 )); then
    echo "$failed of $runs runs did not measure; the distribution above is incomplete" >&2
    exit 1
fi
