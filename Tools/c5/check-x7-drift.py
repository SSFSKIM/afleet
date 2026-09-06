#!/usr/bin/env python3
"""Does the shipped X7 protocol still match what the documents declare?

C5's Task 2 review found the same defect three times: a signature changed in the code and
stayed stale in a document another child copies from. Prose review kept missing it because the
two live pages apart. This compares them mechanically.

Source of truth is Workbench/Sources/PanelHostAPI. The documents checked are the ones a later
child builds from: C5's plan (its canonical Code block), C5's spec (X7's shape and the parent
amendment) and C7's spec (the Revision Note C7.2 inherits).

What it compares, and why each choice is what it is — the first version of this script got all
four of these wrong and caught one injected drift in five:

- **Whole normalised declarations**, not just the `async` effect. A parameter or a return type
  drifting is as fatal to a child copying the block as an effect drifting.
- **Keyed by (protocol, member)**, not by bare name. `register` is declared by both
  `LinkRouterCapability` and `PanelHost`; keying by name made every such member permanently
  exempt, and at the moment of the drift this script was written to catch, `unregister` was in
  exactly that state.
- **Parsed line by line**, with continuation lines joined until the parentheses balance. A
  multi-line regex silently skipped any declaration whose name carried a generic clause, and its
  greedy trailing whitespace class ate the line after every declaration that ended at its
  closing parenthesis.
- **Counts mean coverage.** Every requirement line inside a checked protocol must parse, in the
  source and in the documents alike. A line that looks like a requirement and does not parse is
  a failure, not a silent omission — the first version printed "16 protocol members" against a
  target that declared nineteen, and that number read like success.

A document is checked in one of two modes, declared below and never inferred:

- `decls` — the document spells X7 out in Swift, in fenced blocks or in backticked snippets.
  Every declaration is compared whole, and a protocol block that omits a shipped member is
  drift in its own right.
- `names` — the document describes X7 in prose. Only the member *inventory* is checked: every
  shipped member must be mentioned. **Effects and signatures in a prose document are not
  machine-checked**, because guessing at them from sentences is the same false confidence this
  script exists to remove. If that document needs its effects guarded, it needs a Swift block.

Exit 0 clean, 1 on drift or on a coverage failure. Run from the repository root.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "Workbench/Sources/PanelHostAPI"
DOCS = [
    (ROOT / "docs/doperpowers/plans/2026-09-06-c5-app-shell.md", "decls"),
    (ROOT / "docs/doperpowers/specs/2026-09-05-c7-workbench-panels.md", "decls"),
    (ROOT / "docs/doperpowers/specs/2026-09-06-c5-app-shell.md", "names"),
]

PROTOCOL = re.compile(r"\bprotocol\s+([A-Za-z_]\w*)")
REQUIREMENT = re.compile(r"^(?:func|var)\s+([A-Za-z_]\w*)")
BACKTICKED = re.compile(r"`([^`\n]*\bfunc\s+[A-Za-z_]\w*\s*\([^`\n]*)`")


def normalise(text):
    """One declaration as a single comparable string: no comment, no runs of whitespace."""
    return " ".join(text.split("//")[0].split())


def parse_protocols(text, wanted=None):
    """Every protocol requirement in `text`, line by line.

    Returns `(decls, unparsed, protocols)` where `decls` maps `(protocol, member)` to
    `(normalised declaration, line number)`, and `unparsed` lists every line inside a checked
    protocol body that looked like a requirement and could not be read. Continuation lines are
    joined until the parentheses balance, so a declaration wrapped across lines is one entry.
    """
    lines = text.splitlines()
    decls, unparsed, protocols = {}, [], set()
    current, depth, index = None, 0, 0

    while index < len(lines):
        raw = lines[index]
        line = raw.split("//")[0]
        stripped = line.strip()

        if current is None:
            match = PROTOCOL.search(line)
            if match and "{" in line:
                opened = line.count("{") - line.count("}")
                if opened > 0:
                    current, depth = match.group(1), opened
                    protocols.add(current)
            index += 1
            continue

        checked = wanted is None or current in wanted
        requirement = REQUIREMENT.match(stripped)
        if depth == 1 and requirement and checked:
            chunk, end = stripped, index
            while chunk.count("(") != chunk.count(")") and end + 1 < len(lines):
                end += 1
                chunk += " " + lines[end].split("//")[0].strip()
            if chunk.count("(") != chunk.count(")"):
                unparsed.append((index + 1, stripped))
            else:
                decls[(current, requirement.group(1))] = (normalise(chunk), index + 1)
            depth += chunk.count("{") - chunk.count("}")
            index = end + 1
        else:
            if depth == 1 and checked and stripped and not stripped.startswith(("///", "//", "#", "}")):
                unparsed.append((index + 1, stripped))
            depth += line.count("{") - line.count("}")
            index += 1

        if depth <= 0:
            current, depth = None, 0

    return decls, unparsed, protocols


def backticked_declarations(text, shipped, shipped_protocols):
    """Inline `func …` snippets in prose, as `(protocol, member, normalised, line number)`.

    A snippet is only checked when the prose around it attributes it to an X7 protocol: either
    the snippet carries its own `protocol X {` for a shipped X, or the paragraph it sits in names
    exactly one shipped protocol that declares that member. Both documents sketch other
    children's seams the same way — `FleetBrowserModel` has a `select`, `ChannelTimelineModel` an
    `open` — and matching those on the bare member name would report drift against types X7 does
    not own. Attribution is what makes an inline check sound; without it the check is noise.
    """
    found = []
    offset = 0
    for paragraph in re.split(r"(\n[ \t]*\n)", text):
        if paragraph.strip():
            named = {p for p in shipped_protocols if re.search(rf"\b{p}\b", paragraph)}
            for match in BACKTICKED.finditer(paragraph):
                span = match.group(1)
                enclosing = PROTOCOL.search(span)
                context = {enclosing.group(1)} & shipped_protocols if enclosing else named
                line = text[:offset + match.start()].count("\n") + 1
                for piece in re.finditer(r"func\s+([A-Za-z_]\w*)\s*\([^{}]*", span):
                    member = piece.group(1)
                    owners = sorted(p for p in context if (p, member) in shipped)
                    if owners:
                        found.append((owners, member, normalise(piece.group(0)), line))
        offset += len(paragraph)
    return found


def main():
    # The shipped contract, from the real sources.
    shipped, shipped_unparsed = {}, []
    for path in sorted(SRC.glob("*.swift")):
        decls, unparsed, _ = parse_protocols(path.read_text())
        shipped.update(decls)
        shipped_unparsed += [(path.relative_to(ROOT), line, text) for line, text in unparsed]

    problems = []
    if not shipped:
        problems.append("no protocol requirement found under Sources/PanelHostAPI — "
                        "the walk is broken, not the contract")
    for path, line, text in shipped_unparsed:
        problems.append(f"{path}:{line}: requirement did not parse: {text}")

    shipped_protocols = {protocol for protocol, _ in shipped}
    shipped_members = {member for _, member in shipped}
    print(f"X7 drift check: {len(shipped)} requirements across {len(shipped_protocols)} protocols, "
          f"{len(DOCS)} documents")

    for path, mode in DOCS:
        text = path.read_text()
        name = path.relative_to(ROOT)
        checked = 0

        if mode == "names":
            mentioned = set(re.findall(r"[A-Za-z_]\w*", text))
            missing = sorted(shipped_members - mentioned)
            checked = len(shipped_members) - len(missing)
            for member in missing:
                problems.append(f"{name}: describes X7 but never mentions `{member}`")
            print(f"  {name}: mode names, {checked} of {len(shipped_members)} member names present")
        else:
            decls, unparsed, protocols = parse_protocols(text, wanted=shipped_protocols)
            for line, snippet in unparsed:
                problems.append(f"{name}:{line}: requirement inside an X7 protocol did not parse: {snippet}")
            for key, (declaration, line) in sorted(decls.items(), key=lambda item: item[1][1]):
                checked += 1
                if key not in shipped:
                    problems.append(f"{name}:{line}: declares `{key[0]}.{key[1]}`, "
                                    f"which the shipped protocol does not")
                elif declaration != shipped[key][0]:
                    problems.append(f"{name}:{line}: declares `{declaration}`; "
                                    f"the shipped protocol declares `{shipped[key][0]}`")
            # A block that names an X7 protocol must carry all of it; an omitted member is drift.
            for protocol in sorted(protocols & shipped_protocols):
                for owner, member in sorted(shipped):
                    if owner == protocol and (owner, member) not in decls:
                        problems.append(f"{name}: declares protocol `{protocol}` but omits `{member}`")
            for owners, member, declaration, line in backticked_declarations(text, shipped,
                                                                              shipped_protocols):
                # A paragraph may name more than one protocol that declares this member —
                # `unregister` belongs to both. A correct quote matches exactly one of them; a
                # drifted quote matches none, and the report then names every candidate.
                if all((owner, member) in decls for owner in owners):
                    continue          # already compared as part of a full protocol block
                checked += 1
                if not any(declaration == shipped[(owner, member)][0] for owner in owners):
                    shapes = "; ".join(f"{owner}: `{shipped[(owner, member)][0]}`" for owner in owners)
                    problems.append(f"{name}:{line}: quotes `{declaration}`; "
                                    f"the shipped protocol declares {shapes}")
            print(f"  {name}: mode decls, {checked} declarations compared")

        if checked == 0:
            problems.append(f"{name}: contributed nothing to the check — the document was "
                            f"reformatted, moved, or is no longer where X7 is written")

    if problems:
        print("\n".join("  DRIFT  " + problem for problem in problems))
        return 1
    print("  clean — every document agrees with the shipped declarations, and each contributed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
