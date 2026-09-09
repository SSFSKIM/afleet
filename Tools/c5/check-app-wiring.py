#!/usr/bin/env python3
"""Is every member the app declares actually reached by the app?

Tracker entry 72. Two defects in one C5 review cycle had the same shape: a member
declared in `App/`, correct, tested, and with no production caller at all —
`PanelHostModel.selectIndex(_:in:)` while the menu called something that indexed a
different list, and `ChannelTimelineRegistry.release(_:)` while every channel ever
opened kept its ingestion. Both were found by hand. A green test proves the model
behaves; it says nothing about which path the app takes to it, and that gap is what
this check closes.

The rule: a member declared under `App/` whose name is referenced in `AppTests/` and
nowhere in `App/` outside its own declaration is a finding. Everything else — a member
called by neither, a member called by both — is not; unexercised production code is a
coverage question and this check is about wiring, not coverage.

Three things it deliberately does not treat as a call, because each would make the
check fail open:

- The declaration line itself. Counting it would exempt every member.
- A doc comment. `/// Calls `foo()`` is prose, not a call site.
- A string literal. A name inside one is a storage key or a log line — but what a
  `\\(…)` interpolates inside one is code, and is kept.

And two it deliberately does not treat as a finding:

- SwiftUI's own requirements (`body`, `makeNSView`, …) and the entry point, which the
  framework calls and no afleet source does.
- Anything on the allowlist below, which names the members that are legitimately
  unexercised by this child and says why for each. An entry whose reason is a tracker
  number is not an exemption: it is a pointer at the line that owns the gap.

**What it cannot see, and what to do about that.** The check keys on a bare name, so a
member whose name is also declared or called elsewhere under `App/` is invisible to it —
`PanelHostModel.run(_:)` has no production caller and this check will never say so,
because `LaunchSequence.run()` and `NotificationSpike.run()` share the name. Per-clause
wiring is therefore still read by hand at the merge; this closes the mechanical half.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "App"
TESTS = ROOT / "AppTests"

# Members that are legitimately declared here and called from somewhere this check cannot
# see. Each entry carries its reason; an entry with no reason is not an allowlist entry.
ALLOWLIST: dict[str, str] = {
    # `registerPaneRunner`'s entry was retired 2026-09-09 by C7.4, the leaf its reason named:
    # `AppModel.init` registers the Terminal panel's pane runner, so X7's seam has a production
    # caller. Retired rather than re-worded, for the reason the C6 entries below record.
    # Contract Y1 and Y4's skeleton entries — `register`, `show` and `agentNavigation` — were
    # retired 2026-09-09 by C6.1 Task 4, which is the leaf that supplies all three call sites:
    # `AppModel.init` claims the eleven row kinds through `RowRegistry.register(kind:builder:)`, and
    # the `Agent` chip calls `AgentNavigating.show(run:in:)` on the `agentNavigation` the composition
    # root installs. An allowlist entry outlives its reason silently, so they are removed rather
    # than re-worded. `edit` was retired 2026-09-09 by C6.1 Task 7 for the same reason: contract Y6's
    # *Edit* row action on a past user message is `ComposerModel.edit(_:)`'s production caller.
    # `retains` was retired 2026-09-09 by C6.1 Task 8, which is the mount its entry named:
    # `TimelineListView.retained(_:by:)` filters the channel's rows through
    # `RetractionRegistry.retains(_:)` before the table is handed them, so D11's render-time filter
    # has a production caller.
    # Requirements of a FleetKit protocol, called by FleetKit and never by App/.
    "confirm": "a `StrategyUI` requirement (FleetKit). `StrategyExecutor.run` calls it through the "
               "`ui:` the composer hands itself in as, so its caller is outside App/ by construction "
               "\u2014 the same category the FRAMEWORK set covers for SwiftUI, for a protocol this "
               "check does not know about",
    # Requirements of a Workbench protocol, called by Workbench and never by App/.
    "sourceControlSession": "a `SourceControlTabHost` requirement (Workbench/SourceControlPanel). "
                            "`AppModel.init` registers the tab with itself as the host, and the "
                            "one caller is the `.commit` target's handler inside "
                            "`SourceControlTab.linkTargets()` \u2014 outside App/ by construction, "
                            "which is what X7 handing a panel a capability and never the host "
                            "means. C7.7's G3 asserts the per-destination answer directly, which "
                            "is what makes it visible here at all",
    "filesSession": "a `FilesTabHost` requirement (Workbench/FilesPanel), on exactly the terms of "
                    "its Source Control twin above: `AppModel.init` registers the tab with itself "
                    "as the host and the callers are the `.file` and `.diff` handlers inside "
                    "`FilesTab.linkTargets()`. It escaped this check until 2026-09-09, when the "
                    "corrective that closed tracker 240 named it directly \u2014 a delivery with no "
                    "originating channel is the one case that cannot be raised through the router",
    # Probes that exist for the suite and say so where they are declared.
    "pump": "a test-only probe on ActivityModel, named as one where it is declared",
    "settle": "a test-only probe on NotificationRouter, named as one where it is declared",
    "whenChanged": "a test-only probe on FleetBrowserModel, named as one where it is declared",
    "whenSettled": "a test-only probe on ActivityModel, named as one where it is declared",
    "cursorsPersisted": "a test-only probe on ActivityModel, named as one where it is declared",
    # Deliberate, and argued where it is declared.
    "configChange": "named so a reader of the router knows the second hook id exists; the default "
                    "arm answers it and branching on it would be one more place to forget",
    # Filed. An entry here is not an exemption — it is a pointer at the tracker line that owns it.
    "shutdown": "tracker 71: what ends an owned child on quit is the pipe, and the Quit clause that "
                "would call this is C6's",
    "liveSessionCount": "tracker 73: a count declared for a diagnostics line this child never emits",
    "liveChannelCount": "tracker 73: a count declared for a diagnostics line this child never emits",
    "targetCount": "tracker 73: a count declared for a diagnostics line this child never emits",
    "openChannels": "tracker 73: a count declared for a report this child never emits",
    "skippedWithoutCWDCount": "tracker 73: a count declared for a diagnostics line this child never emits",
    "restore": "tracker 73: superseded by paint(_:listing:origin:), which is what the coordinator calls",
    "setupState": "tracker 73: RootView switches on AppRoute directly; the accessor is the suite's "
                  "surface on the route's payload",
    "upgradeVersions": "tracker 73: RootView switches on AppRoute directly; the accessor is the "
                       "suite's surface on the route's payload",
    "offersOwnedActions": "tracker 74: C5's sidebar offers no channel action, so the row's read-only "
                          "affordance has no consumer yet",
    "readOnlyReason": "tracker 74: C5's sidebar offers no channel action, so the row's read-only "
                      "affordance has no consumer yet",
}

# Names the frameworks call and no afleet source does.
FRAMEWORK = {"body", "main", "init", "deinit", "makeNSView", "updateNSView", "makeCoordinator",
             "applicationDidFinishLaunching", "applicationShouldTerminate", "id", "hash",
             "description", "makeIterator", "next", "encode", "callAsFunction"}

DECL = re.compile(
    r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|package\s+|final\s+|static\s+|class\s+|"
    r"nonisolated\s+|override\s+|mutating\s+|lazy\s+|weak\s+|unowned\s+|convenience\s+|required\s+)*"
    r"(func|var|let)\s+([A-Za-z_][A-Za-z0-9_]*)")


def swift_files(base: Path) -> list[Path]:
    return sorted(p for p in base.rglob("*.swift") if "/.build/" not in str(p))


def strip_noise(text: str) -> str:
    """Comments and string literals blanked, so neither can look like a call site.

    Every newline survives: the caller reports `file:line`, and a stripper that swallowed the
    newlines inside a block comment or a multi-line literal would report every declaration below
    one at the wrong line.
    """
    out, i, n = [], 0, len(text)

    def blank(chunk: str) -> None:
        """Blanks a literal but keeps what `\\(…)` interpolates, which is code and can be a call."""
        j, m = 0, len(chunk)
        while j < m:
            if chunk.startswith("\\(", j):
                depth, k = 1, j + 2
                while k < m and depth:
                    if chunk[k] == "(":
                        depth += 1
                    elif chunk[k] == ")":
                        depth -= 1
                    k += 1
                out.append("  " + chunk[j + 2:k])
                j = k
            else:
                out.append(chunk[j] if chunk[j] == "\n" else " ")
                j += 1

    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            start = i
            while i < n and text[i] != "\n":
                i += 1
            blank(text[start:i])
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            start, depth, i = i, 1, i + 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth += 1; i += 2
                elif text.startswith("*/", i):
                    depth -= 1; i += 2
                else:
                    i += 1
            blank(text[start:i])
        elif c == '"':
            start = i
            if text.startswith('"""', i):
                i += 3
                while i < n and not text.startswith('"""', i):
                    i += 1
                i += 3
            else:
                i += 1
                while i < n and text[i] != '"':
                    i += 2 if text[i] == "\\" else 1
                i += 1
            blank(text[start:min(i, n)])
        else:
            out.append(c)
            i += 1
    return "".join(out)


def findings() -> list[tuple[str, Path, int]]:
    """Every member declared under `APP` that only `TESTS` calls, with where it is declared."""
    declarations: dict[str, list[tuple[Path, int]]] = {}
    for path in swift_files(APP):
        for number, line in enumerate(path.read_text().split("\n"), start=1):
            match = DECL.match(line)
            if not match:
                continue
            name = match.group(2)
            if name in FRAMEWORK or name.startswith("_"):
                continue
            declarations.setdefault(name, []).append((path, number))

    app_bodies = {path: strip_noise(path.read_text()) for path in swift_files(APP)}
    test_bodies = {path: strip_noise(path.read_text()) for path in swift_files(TESTS)}


    found: list[tuple[str, Path, int]] = []
    for name, sites in sorted(declarations.items()):
        word = re.compile(r"\b%s\b" % re.escape(name))
        declared_at = {(path, number) for path, number in sites}
        app_uses = 0
        for path, body in app_bodies.items():
            for number, line in enumerate(body.split("\n"), start=1):
                if (path, number) in declared_at:
                    continue
                app_uses += len(word.findall(line))
        if app_uses:
            continue
        test_uses = sum(len(word.findall(body)) for body in test_bodies.values())
        if not test_uses:
            continue
        if name in ALLOWLIST:
            continue
        found.append((name, *sites[0]))
    return found


def main() -> int:
    found = findings()
    print(f"allowlisted: {len(ALLOWLIST)}")
    print(f"declared in App/, called only from AppTests/: {len(found)}")
    for name, path, number in found:
        print(f"  {name} ({path.relative_to(ROOT)}:{number})")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
