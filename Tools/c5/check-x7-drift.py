#!/usr/bin/env python3
"""Does the shipped X7 protocol still match what the documents declare?

C5's Task 2 review found the same defect three times: a signature changed in the code and
stayed stale in a document another child copies from. Prose review kept missing it because the
two live pages apart. This compares them mechanically.

Source of truth is Workbench/Sources/PanelHostAPI. The documents checked are the ones a later
child builds from: C5's plan (its canonical Code block), C5's spec (X7's shape and the parent
amendment) and C7's spec (the Revision Note C7.2 inherits).

Exit 0 clean, 1 on drift. Run from the repository root.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "Workbench/Sources/PanelHostAPI"
DOCS = [ROOT / "docs/doperpowers/plans/2026-09-06-c5-app-shell.md",
        ROOT / "docs/doperpowers/specs/2026-09-06-c5-app-shell.md",
        ROOT / "docs/doperpowers/specs/2026-09-05-c7-workbench-panels.md"]

# Every protocol requirement the target ships, as (name, "async"/""), from the real sources.
decl = re.compile(r"^\s*func\s+(\w+)\s*\([^)]*\)\s*(async)?", re.M)
shipped = {}
for f in sorted(SRC.glob("*.swift")):
    for name, is_async in decl.findall(f.read_text()):
        shipped.setdefault(name, set()).add("async" if is_async else "sync")

if not shipped:
    sys.exit("no func declarations found under Sources/PanelHostAPI — the walk is broken, "
             "not the contract")

bad = []
# A member the code declares `async` must never appear in a doc without it, and vice versa.
for name, kinds in sorted(shipped.items()):
    if len(kinds) != 1:
        continue                      # overloaded across files; not this check's business
    kind = kinds.pop()
    for doc in DOCS:
        text = doc.read_text()
        for m in re.finditer(rf"^\s*func\s+{re.escape(name)}\s*\([^)]*\)\s*(async)?\s*$",
                             text, re.M):
            doc_kind = "async" if m.group(1) else "sync"
            if doc_kind != kind:
                line = text[:m.start()].count("\n") + 1
                bad.append(f"{doc.relative_to(ROOT)}:{line}: declares `{name}` {doc_kind}, "
                           f"the shipped protocol is {kind}")

print(f"X7 drift check: {len(shipped)} protocol members, {len(DOCS)} documents")
if bad:
    print("\n".join("  DRIFT  " + b for b in bad))
    sys.exit(1)
print("  clean — no document declares a member with a different effect from the code")
