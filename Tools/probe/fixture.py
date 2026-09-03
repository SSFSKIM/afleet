"""Fixture layout (contract X8, spec §4.4): snapshot, streams, artifacts, atomic assembly, load.

Two properties this module is responsible for:

*Nothing under a config home is written.* `snapshot` reads the session's transcript files
and writes copies into the fixture; it never moves, renames or truncates a source file.

*No unredacted byte reaches disk.* Every byte this module writes has been through the
redactor first. A file the rules cannot read -- anything that is not UTF-8 -- is not
copied through: it is replaced by a JSON stub naming its size, because content the rules
cannot inspect is also content `verify`'s scanners cannot inspect, and a fixture must not
carry a hole the tooling is blind to.
"""
import glob
import json
import os
import re
import shutil
import tempfile

SLUG_TOKEN = "_slug_"
ARTIFACT_TOKEN = "<artifacts>"
REQUIRED_FILES = ("fixture.json", "frames.ndjson", "census.json", "redaction.json", "streams.json")


def slug_of(cwd):
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def find_session(config_home, session_id):
    hits = glob.glob(os.path.join(config_home, "projects", "*", session_id + ".jsonl"))
    if not hits:
        raise FileNotFoundError("no transcript for %s under %s/projects" % (session_id, config_home))
    slug = os.path.basename(os.path.dirname(hits[0]))
    return slug, os.path.join(config_home, "projects")


def _session_files(projects_dir, slug, session_id):
    base = os.path.join(projects_dir, slug)
    rel = []
    for p in glob.glob(os.path.join(base, session_id + "*")):
        if os.path.isfile(p):
            rel.append(os.path.relpath(p, projects_dir))
        elif os.path.isdir(p):
            for root, _, files in os.walk(p):
                for f in files:
                    rel.append(os.path.relpath(os.path.join(root, f), projects_dir))
    return sorted(rel)


def _omitted_stub(kind, raw):
    """What stands in for content the redaction rules cannot read."""
    return json.dumps({"omitted": kind, "bytes": len(raw)})


def _redact_file(src, dest, redactor):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(src, "rb") as fh:
        raw = fh.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        # Not copied through: see the module docstring. The stub is valid JSON and valid
        # UTF-8, so a second `redact` pass over a committed fixture leaves it alone.
        with open(dest, "w", encoding="utf-8") as out:
            out.write(_omitted_stub("undecodable file", raw))
        return
    if src.endswith(".jsonl"):
        lines = []
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                lines.append(json.dumps(redactor.redact_json(json.loads(line))))
            except ValueError:
                lines.append(redactor.redact_text(line))
        text = "\n".join(lines) + ("\n" if lines else "")
    else:
        try:
            text = json.dumps(redactor.redact_json(json.loads(text)))
        except ValueError:
            text = redactor.redact_text(text)
    with open(dest, "w", encoding="utf-8") as out:
        out.write(text)


def snapshot(config_home, session_id, dest_dir, redactor):
    """Copy (never move) the session's transcript files, redacted, with the slug rewritten."""
    slug, projects_dir = find_session(config_home, session_id)
    sizes = {}
    for rel in _session_files(projects_dir, slug, session_id):
        token_rel = rel.replace(slug, SLUG_TOKEN, 1)
        dest = os.path.join(dest_dir, token_rel)
        _redact_file(os.path.join(projects_dir, rel), dest, redactor)
        sizes[token_rel] = os.path.getsize(dest)
    return sizes


def stream_sizes(initial_dir):
    out = {}
    for root, _, files in os.walk(initial_dir):
        for f in files:
            p = os.path.join(root, f)
            out[os.path.relpath(p, initial_dir)] = os.path.getsize(p)
    return out


def _strings(obj):
    if isinstance(obj, dict):
        for v in obj.values():
            for s in _strings(v):
                yield s
    elif isinstance(obj, list):
        for v in obj:
            for s in _strings(v):
                yield s
    elif isinstance(obj, str):
        yield obj


def default_task_root():
    return "/private/tmp/claude-%d" % os.getuid()


def collect_artifacts(frames, record_dirs, dest_dir, redactor, task_root=None):
    """Copy files under the CLI's task root that frames or records name, redacted in memory before the
    first write; a file that is not UTF-8 is replaced by a JSON stub naming its size (no binary bytes are
    stored). Returns abs -> token path."""
    task_root = task_root or default_task_root()
    candidates = set()
    for f in frames:
        for s in _strings(f):
            if s.startswith(task_root) or s.startswith(task_root.replace("/private/tmp", "/tmp")):
                candidates.add(s)
    for d in record_dirs:
        for root, _, files in os.walk(d):
            for name in files:
                with open(os.path.join(root, name), encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        for m in re.finditer(re.escape(task_root) + r"[^\s\"']+", line):
                            candidates.add(m.group(0))
    mapping = {}
    for path in sorted(candidates):
        real = path.replace("/tmp/claude-", "/private/tmp/claude-", 1) if path.startswith("/tmp/") else path
        if not os.path.isfile(real):
            continue
        rel = os.path.relpath(real, task_root)
        dest = os.path.join(dest_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(real, "rb") as fh:
            raw = fh.read()
        try:
            text = redactor.redact_text(raw.decode("utf-8"), path="artifacts/" + rel)
        except UnicodeDecodeError:
            text = _omitted_stub("binary artifact", raw)
        with open(dest, "w", encoding="utf-8") as out:
            out.write(text)
        mapping[path] = ARTIFACT_TOKEN + "/" + rel
    return mapping


def tokenise(obj, mapping):
    if not mapping:
        return obj
    if isinstance(obj, dict):
        return {k: tokenise(v, mapping) for k, v in obj.items()}
    if isinstance(obj, list):
        return [tokenise(v, mapping) for v in obj]
    if isinstance(obj, str):
        for k in sorted(mapping, key=len, reverse=True):
            if k in obj:
                obj = obj.replace(k, mapping[k])
        return obj
    return obj


def write_fixture(fixtures_root, name, meta, frames, census_obj, manifest, initial_dir, transcript_dir, artifacts_dir):
    os.makedirs(fixtures_root, exist_ok=True)
    # `verify` requires fixture.json's name to equal the directory it sits in. Establishing
    # it here makes that invariant hold by construction rather than by the caller's care.
    meta = dict(meta, name=name)
    tmp = tempfile.mkdtemp(prefix=".tmp-%s-" % name, dir=fixtures_root)
    try:
        with open(os.path.join(tmp, "fixture.json"), "w", encoding="utf-8") as fh:
            json.dump(meta, fh, indent=1, sort_keys=True)
        with open(os.path.join(tmp, "frames.ndjson"), "w", encoding="utf-8") as fh:
            for rec in frames:
                fh.write(json.dumps(rec) + "\n")
        with open(os.path.join(tmp, "census.json"), "w", encoding="utf-8") as fh:
            json.dump(census_obj, fh, indent=1, sort_keys=True)
        with open(os.path.join(tmp, "redaction.json"), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=1, sort_keys=True)
        for sub, src in (("initial", initial_dir), ("transcript", transcript_dir), ("artifacts", artifacts_dir)):
            dst = os.path.join(tmp, sub)
            if src and os.path.isdir(src):
                shutil.copytree(src, dst)
            else:
                os.makedirs(dst)
        with open(os.path.join(tmp, "streams.json"), "w", encoding="utf-8") as fh:
            json.dump(stream_sizes(os.path.join(tmp, "initial")), fh, indent=1, sort_keys=True)
        dest = os.path.join(fixtures_root, name)
        old = None
        if os.path.exists(dest):
            old = tempfile.mkdtemp(prefix=".old-%s-" % name, dir=fixtures_root)
            os.rmdir(old)
            os.rename(dest, old)
        os.rename(tmp, dest)
        if old:
            shutil.rmtree(old)
        return dest
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


def load(path):
    with open(os.path.join(path, "fixture.json"), encoding="utf-8") as fh:
        meta = json.load(fh)
    frames = []
    with open(os.path.join(path, "frames.ndjson"), encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                frames.append(json.loads(line))
    with open(os.path.join(path, "census.json"), encoding="utf-8") as fh:
        c = json.load(fh)
    with open(os.path.join(path, "streams.json"), encoding="utf-8") as fh:
        streams = json.load(fh)
    return {"path": path, "meta": meta, "frames": frames, "census": c, "streams": streams}
