#!/usr/bin/env bash
#
# G3's offline proof for child spec docs/doperpowers/specs/2026-09-07-c7.2-editor-core.md.
#
# Clones this repository's branch into a temporary directory — a real clone, so the clone's
# .build and .swiftpm start empty — and runs the Workbench test suite inside a sandbox that
# denies the network. What it proves is the clause G3 exists for, as the accepted
# `[parent-impact]` re-words it: *nothing in the build or the test run reaches the network*.
# Monaco is committed, so the editor bundle needs no fetch.
#
# The bound the same filing names is honest and is checked here rather than assumed: SwiftPM
# still has to resolve the package's two remote dependencies (libghostty-spm and its transitive
# MSDisplayLink). Under a denied network they can only come from SwiftPM's machine-level
# repository cache. A machine that has never fetched them needs that one fetch, and no
# arrangement of this leaf changes that.
#
# A sandbox that silently allowed the network would make the whole proof vacuous, so the denial
# is proven in force during the run: an identically-sandboxed `curl` must fail, and — as a
# positive control, so a machine that is simply offline cannot be mistaken for a working
# sandbox — the same `curl` outside the sandbox must succeed.
#
# Denial is per-process via sandbox-exec. Nothing here touches the machine's network
# configuration, needs privileges, or changes any state outside its own temporary directory,
# which it removes on every exit path.
#
# Usage: Tools/verify-offline-build.sh [branch]    (default: the branch this worktree is on)

set -euo pipefail

readonly SANDBOX_PROFILE='(version 1)(allow default)(deny network*)'
readonly PROBE_URL='https://github.com'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
branch="${1:-$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)}"
# Clone from the common git directory: this checkout is usually a worktree, whose own .git is
# a file rather than a repository.
git_common_dir="$(cd "$(git -C "$repo_root" rev-parse --git-common-dir)" && pwd)"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/afleet-offline-proof.XXXXXX")"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# How many entries a SwiftPM cache directory holds. A directory that does not exist holds none,
# which is a finding this script exists to print — so it must be *counted*, not fatal. Written as
# `ls ... | wc -l` it was fatal: under `set -euo pipefail` the pipeline takes `ls`'s status, the
# assignment takes the pipeline's, and the script died one line before the diagnostic that says
# the cache is empty. A machine cold on this cache is exactly the machine that needs to read it.
cache_entry_count() {
    local directory="$1"
    if [[ ! -d "$directory" ]]; then printf '0\n'; return 0; fi
    find "$directory" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '
}

# `Tools/verify-offline-build.sh --count-cache-entries <dir>` prints that count and exits. It is
# how the empty and missing cases are exercised without deleting a real cache.
if [[ "${1:-}" == "--count-cache-entries" ]]; then
    cache_entry_count "${2:?a directory is required}"
    exit 0
fi

say "== branch: $branch"

# --- 1. The sandbox actually denies the network -------------------------------------------
say
say "== proving the sandbox denies the network"

if curl -sS --max-time 20 -o /dev/null "$PROBE_URL"; then
    say "   control (no sandbox): curl reached the network, exit 0"
else
    fail "control curl failed outside the sandbox: this machine has no network, so a denied" \
         "curl inside the sandbox would prove nothing. Re-run with the network up."
fi

set +e
sandbox-exec -p "$SANDBOX_PROFILE" curl -sS --max-time 20 -o /dev/null "$PROBE_URL" 2>"$work_dir/curl.err"
sandboxed_curl_status=$?
set -e

if [[ $sandboxed_curl_status -eq 0 ]]; then
    fail "curl succeeded under the sandbox profile: the network is NOT denied and this proof" \
         "would be vacuous."
fi
say "   under sandbox: curl failed, exit $sandboxed_curl_status — $(head -1 "$work_dir/curl.err")"

# --- 2. A real, fresh clone ----------------------------------------------------------------
say
say "== cloning $branch into a temporary directory"
clone="$work_dir/clone"
git clone --quiet --branch "$branch" --single-branch "$git_common_dir" "$clone"
say "   HEAD: $(git -C "$clone" rev-parse --short HEAD)"
say "   tracked files: $(git -C "$clone" ls-files | wc -l | tr -d ' ')"

for stale in "$clone/Workbench/.build" "$clone/Workbench/.swiftpm" "$clone/.build"; do
    if [[ -e "$stale" ]]; then fail "the clone is not clean: ${stale#"$clone"/} exists"; fi
done
say "   .build and .swiftpm: absent, as a fresh clone requires"

# --- 3. What resolution will have to come from the cache ------------------------------------
say
say "== remote dependencies SwiftPM must resolve with the network denied"
cache_dir="${HOME}/.swiftpm/cache/repositories"
missing_from_cache=0
while read -r identity; do
    [[ -z "$identity" ]] && continue
    # Package.resolved lower-cases the identity; the cache directory keeps the repository's
    # own spelling, so the match has to be case-insensitive.
    if [[ -n "$(find "$cache_dir" -maxdepth 1 -iname "${identity}-*" 2>/dev/null)" ]]; then
        say "   $identity: present in the SwiftPM repository cache"
    else
        say "   $identity: NOT in the SwiftPM repository cache — resolution will need the network"
        missing_from_cache=1
    fi
done < <(sed -n 's/.*"identity" : "\(.*\)".*/\1/p' "$clone/Workbench/Package.resolved")
# libghostty-spm ships GhosttyKit as a binary target, so a *second* cache is load-bearing:
# SwiftPM's artifact cache, which holds the downloaded xcframework zip.
artifact_cache="${HOME}/.swiftpm/cache/artifacts"
artifact_count="$(cache_entry_count "$artifact_cache")"
if [[ "$artifact_count" -gt 0 ]]; then
    say "   binary artifacts: $artifact_count in the SwiftPM artifact cache"
else
    say "   binary artifacts: the SwiftPM artifact cache is empty — the xcframework will need"
    say "                     the network"
    missing_from_cache=1
fi

if [[ $missing_from_cache -eq 1 ]]; then
    say "   (the run below is expected to fail; that failure is the finding, not a bug)"
fi

# --- 4. Build and test with the network denied ----------------------------------------------
say
say "== sandbox-exec -p '$SANDBOX_PROFILE' swift test --disable-sandbox --package-path Workbench"
# `--disable-sandbox` is required and does not weaken the claim. SwiftPM sandboxes its own
# manifest compilation with sandbox_apply(), which macOS refuses inside an existing sandbox
# ("sandbox_apply: Operation not permitted"), so the manifest fails to compile. Turning
# SwiftPM's inner sandbox off leaves the outer one — which denies the network to *every*
# process in the tree, manifests included — in force, and that is the stronger of the two for
# what G3 asserts.
set +e
( cd "$clone" && sandbox-exec -p "$SANDBOX_PROFILE" swift test --disable-sandbox --package-path Workbench ) \
    2>&1 | tee "$work_dir/test.log"
test_status=${PIPESTATUS[0]}
set -e

say
if [[ $test_status -ne 0 ]]; then
    say "== RESULT: FAILED (exit $test_status) with the network denied"
    say "   Record what the run needed the network for; do not re-run with the network allowed."
    exit "$test_status"
fi

# Both runners report: XCTest's "Executed N tests" for 'All tests', and swift-testing's line.
grep -E "^\s+Executed [0-9]+ tests?, with|Test run with [0-9]+ tests?" "$work_dir/test.log" \
    | tail -2 | sed 's/^[[:space:]]*/   /'
say "== RESULT: PASSED with the network denied."
say "   Bound (accepted [parent-impact]): the dependencies above resolved from SwiftPM's"
say "   machine-level caches — the repository cache for the two source packages, the artifact"
say "   cache for GhosttyKit's xcframework — and not from the network."
