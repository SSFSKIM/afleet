#!/usr/bin/env python3
"""S6: confirm the dialog payload shapes and result enums on the installed baseline binary.

The test is structural, not a bare string search. For every shape this asserts, the script
first finds that shape's *own* definition site -- the anchor -- and then requires each of the
shape's field names and enum values to sit inside the WINDOW bytes that follow it. A hit
therefore means the fields belong to that definition, not merely that the string occurs
somewhere in a 200 MB executable.

Two definition sites matter, because the 2.1.257 reading behind the synthetic fixtures spans
two of them. DIALOGS covers the `request_user_dialog` payload schemas and their `result`
enums. FRAMES covers the stream-json system frames a dialog outcome produces, whose `choice`
enum has to agree with the dialog's `result` enum for the fixtures' consent legs to be right.
A site declares its own window because a schema with long `.describe()` prose is longer than a
bare one; the window is still a bound, not the whole file.

Usage: extract_dialog_enums.py [version-or-path]   (default 2.1.259)
"""
import os
import re
import sys

VERSIONS = os.path.expanduser("~/.local/share/claude/versions")
# name -> (anchor at the shape's own definition, window in bytes, needles required inside it)
DIALOGS = {
    "refusal_fallback_prompt": (
        rb'kind:"refusal_fallback_prompt"', 800,
        [rb'result:m(()=>ee(["retry_fallback","edit_prompt","cancelled"]))', rb'default:"cancelled"',
         rb"originalModel", rb"fallbackModel", rb"apiRefusalCategory", rb"guidanceText", rb"retractedMessageUuids"]),
    "fable_overage_consent_prompt": (
        rb'kind:"fable_overage_consent_prompt"', 800,
        [rb'result:m(()=>ee(["consent","switch_default","cancelled"]))', rb'default:"cancelled"',
         rb"overagesEnabled", rb"modelName", rb"balanceCents", rb"currency"]),
}

FRAMES = {
    "system/model_consent_fallback": (
        rb'subtype:x("model_consent_fallback")', 900,
        [rb'choice:ee(["consent","switch_default","cancelled"])', rb"original_model", rb"original_model_name",
         rb"fallback_model", rb"persisted_as_default"]),
    "system/model_refusal_fallback": (
        rb'subtype:x("model_refusal_fallback")', 2400,
        [rb'trigger:x("refusal")', rb'direction:ee(["retry","revert","sticky"])', rb'scope:ee(["session","local"])',
         rb"original_model", rb"fallback_model", rb"request_id", rb"api_refusal_category",
         rb"api_refusal_explanation", rb"retracted_message_uuids", rb"refused_user_message_uuid"]),
}


def scan(path, sites):
    data = open(path, "rb").read()
    out = {}
    for name, (anchor, window, needles) in sites.items():
        windows = [data[m.start():m.start() + window] for m in re.finditer(re.escape(anchor), data)]
        out[name] = {"anchor": anchor.decode(), "window": window,
                     "definitions": len(windows),
                     "needles_in_definition_window": dict((n.decode(), any(n in w for w in windows)) for n in needles),
                     "context": windows[0].decode("utf-8", "replace") if windows else ""}
    return out


def resolve(version):
    """A version argument names a file or a directory under VERSIONS; a path is taken as given."""
    if os.path.isfile(version):
        return version
    base = os.path.join(VERSIONS, version)
    candidates = [base]
    if os.path.isdir(base):
        candidates += sorted(os.path.join(base, x) for x in os.listdir(base))
    for c in candidates:
        if os.path.isfile(c) and os.path.getsize(c) > 1_000_000:
            return c
    return None


def report(title, hits):
    ok = True
    print("== %s" % title)
    for name, info in sorted(hits.items()):
        print("%s: %d definition(s) of %s (window %d)" % (name, info["definitions"], info["anchor"], info["window"]))
        for needle, present in info["needles_in_definition_window"].items():
            print("   %-48s %s" % (needle, "in window" if present else "NOT in window"))
            ok = ok and present
        ok = ok and info["definitions"] > 0
        print("   context: %s\n" % info["context"])
    return ok


def main():
    version = sys.argv[1] if len(sys.argv) > 1 else "2.1.259"
    path = resolve(version)
    if path is None:
        print("no binary found for %r under %s" % (version, VERSIONS))
        return 2
    print("scanned %s (%d bytes)\n" % (path, os.path.getsize(path)))
    ok = report("dialog definitions", scan(path, DIALOGS))
    ok = report("stream-json frame definitions", scan(path, FRAMES)) and ok
    print("ALL SHAPES STRUCTURALLY CONFIRMED" if ok else
          "NOT CONFIRMED (a definition is missing or a needle sits outside its own definition's window)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
