#!/usr/bin/env python3
"""probe: census | diff | record | snapshot | redact | verify (spec §4.2).

The one composition point. `census.py`, `redact.py`, `harness.py`, `fixture.py` and
`verify.py` never import one another; this module wires them into the six subcommands and
into the scenario contract that every recording and spike scenario is written against.

A scenario is a module under `scenarios/` exposing `META` (a dict) and `run(session, ctx)`.
`META` names the fixture, what the recording serves, whether it joins `diff`, whether it is
compared exactly or by required shape, which of §4.6's two isolation levels it uses, the
`Launch` overrides it needs, its prompts, the fixture whose session it resumes, an optional
`setup(scratch_cwd)` and the spikes it informs. `ctx` carries `cwd`, `config_home`, `name`,
`meta`, `launch` and a `notes` list the scenario appends observations to; those notes reach
`fixture.json`, so a reviewer reads what the run saw without re-deriving it.
"""
import argparse
import datetime
import glob
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import census      # noqa: E402
import fixture     # noqa: E402
import harness     # noqa: E402
import redact      # noqa: E402
import verify      # noqa: E402

SCENARIO_DIR = os.environ.get("AFLEET_SCENARIO_DIR") or os.path.join(HERE, "scenarios")
FIXTURES_ROOT = os.environ.get("AFLEET_FIXTURES_ROOT") or os.path.abspath(os.path.join(HERE, "..", "..", "Fixtures"))
SCRATCH_ROOT = "/tmp/afleet-fixtures"
GLOB_CHARS = "*?["


def log(msg):
    sys.stderr.write(msg + "\n")


def binary_argv(claude):
    """The program to exec, absolutised when it names a path rather than a bare command.

    `Popen` resolves a relative program path against the *child's* new directory, and every
    scenario runs in a fresh scratch cwd under `SCRATCH_ROOT`, so `make probe
    CLAUDE=Tools/fake-claude/fake-claude` -- the form the acceptance gate uses -- would
    exec nothing at all. A bare name carries no separator and is left alone, so an
    installed `claude` is still found on `PATH`.
    """
    binary = os.environ.get("AFLEET_CLAUDE_BINARY") or claude or "claude"
    binary = os.path.expanduser(binary)
    if os.sep in binary:
        binary = os.path.abspath(binary)
    return [binary]


def tool_argv(claude, meta):
    """The binary plus a scenario's binary_args (tests point at a Python stand-in this way)."""
    return binary_argv(claude) + list((meta.get("launch") or {}).get("binary_args") or [])


def claude_version(argv):
    out = subprocess.run(argv + ["--version"], capture_output=True, text=True, timeout=30).stdout.strip()
    return out.split()[0] if out else ""


def claude_help(argv):
    return subprocess.run(argv + ["--help"], capture_output=True, text=True, timeout=30).stdout


def load_scenario(name, scenario_dir=None):
    path = os.path.join(scenario_dir or SCENARIO_DIR, name.replace("-", "_") + ".py")
    if not os.path.isfile(path):
        raise FileNotFoundError("no scenario %s (%s)" % (name, path))
    spec = importlib.util.spec_from_file_location("scenario_" + name.replace("-", "_"), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def scenario_for_fixture(fixture_path, scenario_dir=None):
    with open(os.path.join(fixture_path, "fixture.json"), encoding="utf-8") as fh:
        meta = json.load(fh)
    return load_scenario(meta.get("scenario") or meta["name"], scenario_dir), meta


def fresh_scratch(name, scratch_root=SCRATCH_ROOT):
    d = os.path.join(scratch_root, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    return d


def make_launch(meta, claude, cwd, config_home, resume=None):
    kw = dict(binary=binary_argv(claude)[0], cwd=cwd, config_home=config_home)
    kw.update(meta.get("launch") or {})
    if resume:
        kw["resume"] = resume
    else:
        kw.setdefault("session_id", str(uuid.uuid4()))
    return harness.Launch(**kw)


def resolve_config_home(meta, config_home):
    if config_home is not None:
        return config_home
    return harness.SCRATCH_CONFIG_HOME if meta.get("isolation", "config-home") == "config-home" else None


def scenario_cwd(meta, scratch_root):
    """The scratch directory a scenario runs in.

    A resuming scenario reuses the directory the resumed recording used, because the
    transcript slug is derived from the cwd and a resume that runs somewhere else is a
    different project to the CLI. That directory is made by the scenario it resumes, so it
    is missing whenever this one runs alone -- which `Popen` would report as a bare
    `FileNotFoundError` naming nothing the operator can act on.
    """
    if not meta.get("resume_of"):
        return fresh_scratch(meta["name"], scratch_root)
    cwd = os.path.join(scratch_root, meta["resume_of"])
    if not os.path.isdir(cwd):
        raise FileNotFoundError("%s resumes %s, whose scratch cwd %s is gone; run %s first"
                                % (meta["name"], meta["resume_of"], cwd, meta["resume_of"]))
    return cwd


def run_scenario(mod, claude, config_home, scratch_root, redactor, resume=None):
    meta = mod.META
    cwd = scenario_cwd(meta, scratch_root)
    if callable(meta.get("setup")):
        meta["setup"](cwd)
    launch = make_launch(meta, claude, cwd, resolve_config_home(meta, config_home), resume=resume)
    session = harness.Session(launch, redactor)
    ctx = {"cwd": cwd, "config_home": launch.config_home, "name": meta["name"], "meta": meta, "notes": [], "launch": launch}
    session.start(timeout=60)
    try:
        mod.run(session, ctx)
    finally:
        code = session.close(end_session=not meta.get("keep_open"))
    ctx["exit_code"] = code
    ctx["stderr_tail"] = session.stderr_tail()
    return session, ctx


def resolve_resume(meta, fixtures_root):
    """The session id a scenario resumes, from the fixture named by META['resume_of'] (None when it resumes nothing)."""
    if not meta.get("resume_of"):
        return None
    with open(os.path.join(fixtures_root or FIXTURES_ROOT, meta["resume_of"], "fixture.json"), encoding="utf-8") as fh:
        prior = json.load(fh)
    return prior["session_id"]


def session_id_of(session, launch):
    if session.system_init and session.system_init.get("session_id"):
        return session.system_init["session_id"]
    return launch.resume or launch.session_id


def record(name, claude, scenario_dir=None, fixtures_root=None, config_home=None, scratch_root=SCRATCH_ROOT, reviewer=None):
    fixtures_root = fixtures_root or FIXTURES_ROOT
    mod = load_scenario(name, scenario_dir)
    meta = dict(mod.META)
    redactor = redact.Redactor()
    argv = tool_argv(claude, meta)
    version, help_text = claude_version(argv), claude_help(argv)
    work = tempfile.mkdtemp(prefix="afleet-record-")
    os.chmod(work, 0o700)
    try:
        initial_dir, transcript_dir, artifacts_dir = (os.path.join(work, d) for d in ("initial", "transcript", "artifacts"))
        for d in (initial_dir, transcript_dir, artifacts_dir):
            os.makedirs(d)
        ch = resolve_config_home(meta, config_home)
        resume = resolve_resume(meta, fixtures_root)
        if resume:
            fixture.snapshot(ch or os.path.expanduser("~/.claude"), resume, initial_dir, redactor)
        session, ctx = run_scenario(mod, claude, config_home, scratch_root, redactor, resume=resume)
        sid = session_id_of(session, ctx["launch"])
        frames = session.frames()
        try:
            fixture.snapshot(ctx["config_home"] or os.path.expanduser("~/.claude"), sid, transcript_dir, redactor)
        except FileNotFoundError as e:       # a stand-in writes no transcript; the real CLI always does
            ctx["notes"].append("no transcript to snapshot: %s" % e)
        mapping = fixture.collect_artifacts([r.get("frame") for r in frames if "frame" in r], [transcript_dir], artifacts_dir, redactor)
        if mapping:
            frames = fixture.tokenise(frames, mapping)
            for root, _, files in os.walk(transcript_dir):
                for f in files:
                    p = os.path.join(root, f)
                    with open(p, encoding="utf-8") as fh:
                        text = fh.read()
                    for k, v in mapping.items():
                        text = text.replace(k, v)
                    with open(p, "w", encoding="utf-8") as fh:
                        fh.write(text)
        c = census.census([r["frame"] for r in frames if "frame" in r], help_text=help_text, version=version)
        existing = os.path.join(fixtures_root, meta["name"], "census.json")
        if not meta.get("deterministic") and os.path.isfile(existing):
            with open(existing, encoding="utf-8") as fh:
                c = census.merge_required(json.load(fh), c)
        out_meta = {
            "name": meta["name"], "scenario": name, "purpose": meta.get("purpose"), "serves": meta.get("serves", []),
            "spikes": meta.get("spikes", []),
            "recorded_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "cli_version": version, "session_id": sid, "cwd": ctx["cwd"],
            "launch": {"argv": ctx["launch"].argv(), "env": {k: v for k, v in ctx["launch"].env_table.items()}},
            "prompts": meta.get("prompts", []), "census": bool(meta.get("census", True)), "deterministic": bool(meta.get("deterministic")),
            "isolation": meta.get("isolation", "config-home"), "synthetic": False, "hypothesis": False,
            "late_responses": list(meta.get("late_responses", [])),
            # Read off the session's own cancel record, never inferred from the captured frames:
            # `verify` treats the list as the host declaring which of its requests it withdrew,
            # and a list read back out of the capture would be a blanket amnesty the recorder
            # granted itself. Sorted only so the file is stable; `verify` reads it as a set.
            "withdrawn_requests": sorted(session.withdrawn_requests),
            "notes": ctx["notes"], "exit_code": ctx["exit_code"],
            "review": {"reviewer": reviewer or "", "date": datetime.date.today().isoformat() if reviewer else "", "checklist_version": 1},
        }
        out_meta = redactor.redact_json(out_meta)          # fixture.json is a redaction target too (spec §4.5)
        path = fixture.write_fixture(fixtures_root, meta["name"], out_meta, frames, c, redactor.manifest(), initial_dir, transcript_dir, artifacts_dir)
    finally:
        # A run that dies mid-recording must not leave the staging directory behind. For a
        # resume it already holds the prior session's transcript -- redacted, but still a
        # copy of a recording nothing will ever come back for.
        shutil.rmtree(work, ignore_errors=True)
    errors, warnings = verify.verify_fixture(path)
    for w in warnings:
        log("warning: " + w)
    return path, errors


def sign(path, reviewer):
    p = os.path.join(path, "fixture.json")
    with open(p, encoding="utf-8") as fh:
        meta = json.load(fh)
    meta["review"] = {"reviewer": reviewer, "date": datetime.date.today().isoformat(), "checklist_version": 1}
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=1, sort_keys=True)


def expand_fixture_paths(paths):
    """Fixture directories from command-line arguments, tolerating an unexpanded glob.

    `make verify-fixtures` passes `Fixtures/*/`, which the shell hands through verbatim when
    it matches nothing -- and it matches nothing until the first fixture is recorded. A
    pattern that expands to no directory is no fixtures, not one broken one. A plain path is
    passed through even when it is missing, because a fixture named by hand and not there is
    exactly the failure this command exists to report.
    """
    out = []
    for p in paths:
        p = p.rstrip("/")
        if not os.path.isdir(p) and any(ch in p for ch in GLOB_CHARS):
            out.extend(sorted(m.rstrip("/") for m in glob.glob(p) if os.path.isdir(m)))
        else:
            out.append(p)
    return out


def verify_paths(paths, hostname=None):
    failed, lines = 0, []
    for p in expand_fixture_paths(paths):
        errors, warnings = verify.verify_fixture(p, hostname=hostname)
        for e in errors:
            lines.append("%s: ERROR %s" % (p, e))
        for w in warnings:
            lines.append("%s: warning %s" % (p, w))
        if errors:
            failed += 1
    return failed, "\n".join(lines)


def group_drift(lines):
    """Fold a census diff's correlated lines into one block per subject.

    One observation now produces several correct lines about the same pair: a single error
    `control_response` shows up as a removed required payload key, a removed required body
    key and, in exact mode, an added `error` payload key -- and that multiplies across
    pairs. This output is what an operator reads to decide whether the CLI drifted, so
    nothing is dropped and nothing is summarised away; the lines about one subject are
    simply gathered under it, in the order the subject first appeared. A subject with one
    line keeps its one line.
    """
    order, groups = [], {}
    for line in lines:
        prefix, sep, detail = line.partition(": ")
        if not sep:
            order.append((None, line))
            continue
        if prefix not in groups:
            groups[prefix] = []
            order.append((prefix, None))
        groups[prefix].append(detail)
    out = []
    for prefix, line in order:
        if prefix is None:
            out.append(line)
        elif len(groups[prefix]) == 1:
            out.append("%s: %s" % (prefix, groups[prefix][0]))
        else:
            out.append(prefix + ":")
            out.extend("  " + d for d in groups[prefix])
    return out


def diff(claude, scenario_dir=None, fixtures_root=None, config_home=None, scratch_root=SCRATCH_ROOT, only=None, script=None):
    fixtures_root = fixtures_root or FIXTURES_ROOT
    drifted, report = 0, []
    names = [only] if only else sorted(n for n in os.listdir(fixtures_root) if os.path.isfile(os.path.join(fixtures_root, n, "fixture.json")))
    for n in names:
        fpath = os.path.join(fixtures_root, n)
        # Backed up before the first mutation and restored in the `finally`, so no path out of
        # the block -- including the `continue` for a fixture that does not take part -- can
        # leak a `FAKE_CLAUDE_*` variable into the next fixture's run.
        env_backup = dict(os.environ)
        try:
            mod, meta = scenario_for_fixture(fpath, scenario_dir)
            if not meta.get("census") or meta.get("synthetic"):
                continue
            os.environ["FAKE_CLAUDE_FIXTURE"] = fpath
            if script:
                os.environ["FAKE_CLAUDE_SCRIPT"] = script
            os.environ.setdefault("FAKE_CLAUDE_SPEED", "0")
            argv = tool_argv(claude, mod.META)
            version, help_text = claude_version(argv), claude_help(argv)     # inside the env block so fake-claude answers from this fixture
            session, ctx = run_scenario(mod, claude, config_home, scratch_root, redact.Redactor(), resume=resolve_resume(meta, fixtures_root))
            observed = census.census([r["frame"] for r in session.frames() if "frame" in r], help_text=help_text, version=version)
            with open(os.path.join(fpath, "census.json"), encoding="utf-8") as fh:
                recorded = json.load(fh)
            lines = census.diff(recorded, observed, "exact" if meta.get("deterministic") else "required")
        except Exception as e:
            # `make probe` is a verdict on every fixture, not on the first one that breaks. A
            # scenario that cannot be re-run at all -- a binary that has moved, a resume whose
            # scratch cwd was cleared, a census file that will not parse -- is itself drift
            # worth reporting, and catching it here is what keeps the other fixtures' verdicts
            # on the screen. It counts against the exit status like any other drift.
            drifted += 1
            report.append("%s: FAILED to run (%s: %s)" % (n, type(e).__name__, e))
            continue
        finally:
            os.environ.clear(); os.environ.update(env_backup)
        if lines:
            drifted += 1
            report.append("%s: DRIFT (%d difference%s)" % (n, len(lines), "" if len(lines) == 1 else "s"))
            report += ["  " + l for l in group_drift(lines)]
        else:
            report.append("%s: ok" % n)
    return min(drifted, 125), "\n".join(report)


def _redact_in_place(path):
    """Re-run §4.5 over a committed fixture, idempotently, and rewrite the manifest.

    `census.json` is deliberately left alone. Its pair names sit in key position -- a `user`
    frame is the key `pairs.user` -- and the structural rules read a key as a field name, so
    a pass over it would replace the census of every identity-named pair with a placeholder.
    Its contents are counted off `frames.ndjson`, which this pass does redact, so it carries
    nothing the rules have not already been through; `verify` scans it with the same
    names-only reshaping for the same reason.
    """
    r = redact.Redactor()
    fx = fixture.load(path)
    rs = census.request_subtypes([x["frame"] for x in fx["frames"] if "frame" in x])
    frames = []
    for rec in fx["frames"]:
        if "frame" in rec:
            red = r.redact_frame(rec["frame"], rec["dir"], rs)
            frames.append(dict(rec, frame=red) if red is not None else
                          {"t": rec["t"], "dir": rec["dir"], "dropped": rec["frame"].get("request", {}).get("subtype"),
                           "request_id": rec["frame"].get("request_id")})
        else:
            frames.append(rec)
    with open(os.path.join(path, "frames.ndjson"), "w", encoding="utf-8") as fh:
        for rec in frames:
            fh.write(json.dumps(rec) + "\n")
    with open(os.path.join(path, "fixture.json"), "w", encoding="utf-8") as fh:
        json.dump(r.redact_json(fx["meta"]), fh, indent=1, sort_keys=True)
    for sub in ("initial", "transcript", "artifacts"):
        for root, _, files in os.walk(os.path.join(path, sub)):
            for f in files:
                p = os.path.join(root, f)
                fixture._redact_file(p, p, r)
    with open(os.path.join(path, "redaction.json"), "w", encoding="utf-8") as fh:
        json.dump(r.manifest(), fh, indent=1, sort_keys=True)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="probe")
    sub = ap.add_subparsers(dest="cmd")
    for name in ("census", "diff", "record", "snapshot", "redact", "verify"):
        sp = sub.add_parser(name)
        sp.add_argument("--claude", default=None)
        sp.add_argument("--config-home", default=None)
        if name == "census":
            sp.add_argument("--scenario", nargs="*", default=[])
        if name == "diff":
            sp.add_argument("--fixture", default=None); sp.add_argument("--script", default=None)
        if name == "record":
            sp.add_argument("scenario"); sp.add_argument("--reviewer", default=None)
        if name in ("snapshot", "redact"):
            sp.add_argument("fixture")
        if name == "verify":
            sp.add_argument("fixtures", nargs="+")
            # `verify_fixture` defaults to the local host, which is right where the recording
            # was made. A review elsewhere has to name the recording host or rule 3's hostname
            # half cannot fire at all (spec Revision Note, 2026-09-04).
            sp.add_argument("--hostname", default=None, help="the hostname the fixture was recorded on")
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_usage(); return 2
    if args.cmd == "census":
        out = {}
        for name in ["zero_cost"] + list(args.scenario):
            mod = load_scenario(name)
            argv_b = tool_argv(args.claude, mod.META)
            version, help_text = claude_version(argv_b), claude_help(argv_b)
            session, ctx = run_scenario(mod, args.claude, args.config_home, SCRATCH_ROOT, redact.Redactor(), resume=resolve_resume(mod.META, FIXTURES_ROOT))
            out[mod.META["name"]] = census.census([r["frame"] for r in session.frames() if "frame" in r], help_text=help_text, version=version)
        print(json.dumps(out, indent=1, sort_keys=True)); return 0
    if args.cmd == "diff":
        code, report = diff(args.claude, config_home=args.config_home, only=args.fixture, script=args.script)
        print(report); return code
    if args.cmd == "record":
        path, errors = record(args.scenario, args.claude, config_home=args.config_home, reviewer=args.reviewer)
        print("recorded %s" % path)
        real = [e for e in errors if "review" not in e]
        for e in errors:
            print(("ERROR " if e in real else "needs review: ") + e)
        return 1 if real else 0
    if args.cmd == "snapshot":
        with open(os.path.join(args.fixture, "fixture.json"), encoding="utf-8") as fh:
            meta = json.load(fh)
        ch = args.config_home or (harness.SCRATCH_CONFIG_HOME if meta.get("isolation") == "config-home" else os.path.expanduser("~/.claude"))
        dest = os.path.join(args.fixture, "transcript")
        shutil.rmtree(dest, ignore_errors=True)
        fixture.snapshot(ch, meta["session_id"], dest, redact.Redactor()); return 0
    if args.cmd == "redact":
        _redact_in_place(args.fixture); return 0
    if args.cmd == "verify":
        failed, report = verify_paths(args.fixtures, hostname=args.hostname)
        if report:
            print(report)
        print("%d fixture(s) failed" % failed if failed else "all fixtures pass")
        return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
