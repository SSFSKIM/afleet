#!/usr/bin/env python3
"""probe: census | diff | record | snapshot | redact | verify | sign | synthetic (spec §4.2).

The one composition point. `census.py`, `redact.py`, `harness.py`, `fixture.py` and
`verify.py` never import one another; this module wires them into the eight subcommands and
into the scenario contract below. `sign` and `synthetic` are the two that need no binary:
`sign` writes the review block §4.5 requires and `verify` refuses a fixture without, and
`synthetic` rebuilds the two hand-written dialog fixtures of §4.7 from their schemas.

## The scenario contract

A scenario is a module under `scenarios/` exposing `META` (a dict) and `run(session, ctx)`.

`META` keys, all of them read by this module:

- `name`             the fixture directory this recording lands in, and the scratch cwd it
                     runs in under `SCRATCH_ROOT`.
- `purpose`          one line a reviewer reads first.
- `serves`           the acceptance items and spikes the recording is evidence for.
- `spikes`           the spike ids it informs, so a finding walks back to its evidence.
- `census`           whether `diff` re-runs it against a binary. False excludes it.
- `deterministic`    True compares pair sets, key sets, capabilities and flags exactly;
                     False compares required shapes and accumulates across re-recordings.
- `isolation`        `"config-home"` (§4.6's default) or `"setting"`.
- `launch`           `Launch(...)` overrides: `max_turns`, `model`, `permission_mode`,
                     `extra_flags`, `session_id`, and `binary_args`, which the tests use to
                     point the launch line at a Python stand-in.
- `prompts`          what the recording sent, for the reviewer and for `fixture.json`. It
                     **must** mirror what `run()` actually sends: nothing enforces it, and a
                     fixture whose `prompts` misdescribe its own session is bad evidence.
- `resume_of`        the fixture whose session this one resumes. Its session id becomes
                     `--resume`, its transcript becomes `initial/`, and its scratch cwd is
                     reused, because the transcript slug is derived from the cwd.
- `setup`            optional `callable(scratch_cwd)` creating the synthetic content §4.5
                     requires the model to read.
- `fallback_launch`  `launch` overrides applied to a second recording when `run()` raises
                     `harness.RetryWithFallback`. The first session's capture is discarded
                     whole and only the second reaches the fixture; `fallback_reason` is the
                     one line the note in `fixture.json` gives for why. This exists for the
                     scenario that cannot know its launch line is wrong until it has opened
                     the session -- S5 learns from `system/init.tools` whether the SDK MCP
                     server registered under `--strict-mcp-config`.
- `keep_open`        True suppresses the `end_session` at close. The global constraint
                     forbids ending a session while a background task is still running, and
                     this is how a scenario says so -- `background-shell` sets it.
- `late_responses`   request ids `fixture.json` declares, licensing one response arriving
                     after the CLI cancelled its own request (§4.2).
- `spill_after`      the capture length past which the harness spills to a mode-0600 file in
                     a private directory outside the worktree (§4.2). A scenario expecting a
                     large volume sets it; the harness default applies otherwise.

`withdrawn_requests` is *not* a `META` key. It is written from the ids the scenario passed to
`session.cancel()` and never inferred from the captured frames, which is what keeps it a
declaration about what the host intended rather than an amnesty the recorder grants itself.

`run(session, ctx)` drives the session and returns nothing. `ctx` carries `cwd`,
`config_home`, `name`, `meta`, `launch` and a `notes` list the scenario appends observations
to; those notes reach `fixture.json`, so a reviewer reads what the run saw without
re-deriving it. `exit_code` and `stderr_tail` are added after `run()` returns, for the caller.
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
# `verify`'s unsigned-review error, matched by equality. `record` reports this one as advice
# -- a fresh recording is unsigned by construction and the reviewer signs it next -- and
# every other error as a failure. Equality and not a substring test: `verify` formats a
# scanner hit as a fixture-relative path followed by the hit, so a file whose path merely
# contains the word would demote an unredacted byte to advice and exit 0. If `verify` ever
# rewords this, the mismatch makes `record` fail on an unsigned fixture, which is the safe
# direction to be wrong in.
UNSIGNED_REVIEW = "review block is not signed (needs reviewer, date, checklist_version)"


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
    directory = scenario_dir or SCENARIO_DIR
    # A scenario may import a sibling: `session-mirror-resume` reuses the mirror comparison
    # `session-mirror-relocation` defines, because the two fixtures are one catalogue row and
    # a second copy of that comparison could drift from the first. Modules loaded from a file
    # location are not importable by name, so the directory they came from goes on the path --
    # the directory this call was given, so a scenario set pointed at by `AFLEET_SCENARIO_DIR`
    # imports its own siblings rather than the installed ones.
    if directory not in sys.path:
        sys.path.insert(0, directory)
    path = os.path.join(directory, name.replace("-", "_") + ".py")
    if not os.path.isfile(path):
        raise FileNotFoundError("no scenario %s (%s)" % (name, path))
    spec = importlib.util.spec_from_file_location("scenario_" + name.replace("-", "_"), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fixture_meta(fixture_path):
    with open(os.path.join(fixture_path, "fixture.json"), encoding="utf-8") as fh:
        return json.load(fh)


def takes_part_in_the_census(meta):
    """Whether `diff` re-runs this fixture against a binary, and why not when it does not.

    Returns the reason it is skipped, or None to run it. Asked *before* the fixture's
    scenario is loaded: a synthetic fixture is written from schemas and has no scenario
    module at all, so loading first raised `FileNotFoundError` for the very fixtures this
    test exists to pass over, and the drift ritual reported the two hand-written dialog
    fixtures as failures on a tree where nothing was wrong.
    """
    if meta.get("synthetic"):
        return "synthetic"
    if not meta.get("census"):
        return "census: false"
    return None


def scenario_for_fixture(fixture_path, scenario_dir=None):
    meta = fixture_meta(fixture_path)
    return load_scenario(meta.get("scenario") or meta["name"], scenario_dir), meta


def config_home_paths(extra=None):
    """Every directory nothing here may write into or delete (contract X9, global constraint 3)."""
    homes = [harness.SCRATCH_CONFIG_HOME, os.path.expanduser("~/.claude"),
             os.environ.get("CLAUDE_CONFIG_DIR"), extra]
    return sorted({os.path.realpath(h) for h in homes if h})


def _within(child, parent):
    """`child` is `parent` or sits under it, after symlink resolution.

    The predicate `fake-claude`'s `materialize` already uses to refuse its own destination
    (`Tools/fake-claude/fake_claude.py`, `_within`). Same problem, so the same shape rather
    than a second one that would have to be audited separately.
    """
    child, parent = os.path.realpath(child), os.path.realpath(parent)
    return child == parent or child.startswith(parent.rstrip("/") + os.sep)


def forbidden_config_home(path, extra=None):
    """The config home `path` is, sits inside, or contains -- or None when it touches none.

    Both directions are refused, for different reasons. A path resolving *into* a config home
    is the one X9 names outright: writing or deleting there reaches inside a logged-in Claude
    configuration from within `Tools/`. A path that *contains* one takes the whole home with
    it when it goes. Resolution comes before the comparison because a symlink is exactly how
    a path that does not look like a config home turns out to be one.
    """
    for home in config_home_paths(extra):
        if _within(path, home) or _within(home, path):
            return home
    return None


def fresh_scratch(name, scratch_root=SCRATCH_ROOT, config_home=None):
    """An empty scratch cwd for one scenario, refusing any name that lands on a config home.

    §4.6 puts the scratch config home at `/tmp/afleet-fixtures/config-home` and every
    scenario's scratch cwd at `/tmp/afleet-fixtures/<name>`: siblings under one root. A
    scenario named `config-home`, one whose name resolves to the root itself, and one whose
    scratch root resolves *inside* a config home all end in the same place -- the `rmtree`
    below running within a logged-in Claude configuration, from inside `Tools/`, with no
    warning. Containment is the dangerous relation, and it is dangerous both ways round.
    """
    d = os.path.join(scratch_root, name)
    home = forbidden_config_home(d, config_home)
    if home:
        raise ValueError("scratch cwd %s for scenario %r resolves onto the config home %s; rename the scenario"
                         % (d, name, home))
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


def scenario_cwd(meta, scratch_root, config_home=None):
    """The scratch directory a scenario runs in.

    A resuming scenario reuses the directory the resumed recording used, because the
    transcript slug is derived from the cwd and a resume that runs somewhere else is a
    different project to the CLI. That directory is made by the scenario it resumes, so it
    is missing whenever this one runs alone -- which `Popen` would report as a bare
    `FileNotFoundError` naming nothing the operator can act on.
    """
    if not meta.get("resume_of"):
        return fresh_scratch(meta["name"], scratch_root, config_home)
    cwd = os.path.join(scratch_root, meta["resume_of"])
    if not os.path.isdir(cwd):
        raise FileNotFoundError("%s resumes %s, whose scratch cwd %s is gone; run %s first"
                                % (meta["name"], meta["resume_of"], cwd, meta["resume_of"]))
    return cwd


def run_scenario(mod, claude, config_home, scratch_root, redactor, resume=None):
    meta = mod.META
    home = resolve_config_home(meta, config_home)
    cwd = scenario_cwd(meta, scratch_root, home)
    if callable(meta.get("setup")):
        meta["setup"](cwd)
    launch = make_launch(meta, claude, cwd, home, resume=resume)
    session_kw = {}
    if meta.get("spill_after") is not None:
        # §4.2's spill clause: a scenario that declares a large expected volume spills the
        # capture to a mode-0600 file in a private directory outside the worktree. The
        # harness implements the spill; this is the only place a scenario can ask for it.
        session_kw["spill_after"] = meta["spill_after"]
    session = harness.Session(launch, redactor, **session_kw)
    ctx = {"cwd": cwd, "config_home": launch.config_home, "name": meta["name"], "meta": meta, "notes": [], "launch": launch}
    session.start(timeout=60)
    try:
        mod.run(session, ctx)
    except harness.RetryWithFallback as why:
        # Not an error: the scenario observed that this launch line cannot produce its
        # evidence and asks for the fallback. The session is still closed below, and
        # `record` reads `ctx["retry"]` to decide whether to re-run.
        ctx["notes"].append("retry with fallback launch: %s" % why)
        ctx["retry"] = str(why)
    finally:
        code = session.close(end_session=not meta.get("keep_open"))
    ctx["exit_code"] = code
    ctx["stderr_tail"] = session.stderr_tail()
    return session, ctx


def resolve_resume(meta, fixtures_root):
    """The session id a scenario resumes, from the fixture named by META['resume_of'] (None when it resumes nothing).

    `meta` is the scenario's `META`, never a fixture's `fixture.json`. `resume_of` is a
    property of the scenario and `record` has no reason to write it into the fixture, so
    handing this function a fixture resolves every one of them to `None` and re-runs a
    resuming scenario as a fresh session -- which against a replayer still produces a stream
    and so shows up only as unexplained drift on a real binary.
    """
    if not meta.get("resume_of"):
        return None
    with open(os.path.join(fixtures_root or FIXTURES_ROOT, meta["resume_of"], "fixture.json"), encoding="utf-8") as fh:
        prior = json.load(fh)
    return prior["session_id"]


def session_id_of(session, launch):
    if session.system_init and session.system_init.get("session_id"):
        return session.system_init["session_id"]
    return launch.resume or launch.session_id


def record(name, claude, scenario_dir=None, fixtures_root=None, config_home=None,
           scratch_root=SCRATCH_ROOT, reviewer=None, out=None):
    fixtures_root = fixtures_root or FIXTURES_ROOT
    mod = load_scenario(name, scenario_dir)
    meta = dict(mod.META)
    redactor = redact.Redactor()
    argv = tool_argv(claude, meta)
    version, help_text = claude_version(argv), claude_help(argv)
    if not version:
        # An empty version reaches both `fixture.json` and `census.json`, where `verify` only
        # ever compares them to each other -- and finds them equal. A fixture that passes the
        # gate while claiming no CLI version is worthless as the baseline four children will
        # trust, and it costs nothing to refuse here rather than discover it at a review.
        raise RuntimeError("%s printed no version; refusing to record with an empty cli_version" % " ".join(argv))
    # `--out` (§4.2) names the directory this recording lands in, and its basename becomes the
    # fixture's name. `fixtures_root` stays what a resume is resolved against.
    out_root, out_name = os.path.split(os.path.abspath(out.rstrip("/"))) if out else (fixtures_root, meta["name"])
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
        if ctx.get("retry") and meta.get("fallback_launch"):
            # The first session's capture is dropped whole and the fixture keeps only the
            # second. `mod.META` is rebound because `run_scenario` reads the module's META,
            # and the scenario's own `run()` reads it too; the module was loaded for this
            # call alone, so the rebinding outlives nothing.
            meta = dict(meta)
            meta["launch"] = dict(meta.get("launch") or {}, **meta["fallback_launch"])
            mod.META = meta
            session, ctx = run_scenario(mod, claude, config_home, scratch_root, redactor, resume=resume)
            ctx["notes"].insert(0, "recorded with fallback launch after: %s" % meta.get("fallback_reason", "retry requested"))
        if ctx["exit_code"]:
            # At the terminal, not only in the fixture: twenty live recordings cost real
            # tokens, and an operator who sees the exit as it happens can stop the run.
            log("%s: the recorded session exited %s" % (meta["name"], ctx["exit_code"]))
            tail = (ctx["stderr_tail"] or "").strip()
            if tail:
                log("%s: stderr tail:\n%s" % (meta["name"], tail))
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
        existing = os.path.join(out_root, out_name, "census.json")
        if not meta.get("deterministic") and os.path.isfile(existing):
            with open(existing, encoding="utf-8") as fh:
                c = census.merge_required(json.load(fh), c)
        out_meta = {
            "name": out_name, "scenario": name, "purpose": meta.get("purpose"), "serves": meta.get("serves", []),
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
        path = fixture.write_fixture(out_root, out_name, out_meta, frames, c, redactor.manifest(), initial_dir, transcript_dir, artifacts_dir)
    finally:
        # A run that dies mid-recording must not leave the staging directory behind. For a
        # resume it already holds the prior session's transcript -- redacted, but still a
        # copy of a recording nothing will ever come back for.
        shutil.rmtree(work, ignore_errors=True)
    errors, warnings = verify.verify_fixture(path)
    for w in warnings:
        log("warning: " + w)
    return path, errors


def classify_errors(errors):
    """Split `verify`'s errors into (blocking, advisory).

    Exactly one error is advisory: a fresh recording is unsigned by construction and the
    reviewer signs it next. Every other error, redaction findings above all, blocks.
    """
    return [e for e in errors if e != UNSIGNED_REVIEW], [e for e in errors if e == UNSIGNED_REVIEW]


def sign(path, reviewer):
    p = os.path.join(path, "fixture.json")
    with open(p, encoding="utf-8") as fh:
        meta = json.load(fh)
    meta["review"] = {"reviewer": reviewer, "date": datetime.date.today().isoformat(),
                      "checklist_version": verify.CHECKLIST_VERSION}
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
    drifted, skipped, report = 0, 0, []
    names = [only] if only else sorted(n for n in os.listdir(fixtures_root) if os.path.isfile(os.path.join(fixtures_root, n, "fixture.json")))
    for n in names:
        fpath = os.path.join(fixtures_root, n)
        # Backed up before the first mutation and restored in the `finally`, so no path out of
        # the block -- including the `continue` for a fixture that does not take part -- can
        # leak a `FAKE_CLAUDE_*` variable into the next fixture's run.
        env_backup = dict(os.environ)
        try:
            meta = fixture_meta(fpath)
            why = takes_part_in_the_census(meta)
            if why:
                # Named, not passed over in silence: an omitted directory reads exactly like a
                # fixture that passed, and this report is what says which is which.
                report.append("%s: skipped (%s)" % (n, why))
                skipped += 1
                continue
            mod = load_scenario(meta.get("scenario") or meta["name"], scenario_dir)
            os.environ["FAKE_CLAUDE_FIXTURE"] = fpath
            if script:
                os.environ["FAKE_CLAUDE_SCRIPT"] = script
            os.environ.setdefault("FAKE_CLAUDE_SPEED", "0")
            argv = tool_argv(claude, mod.META)
            version, help_text = claude_version(argv), claude_help(argv)     # inside the env block so fake-claude answers from this fixture
            session, ctx = run_scenario(mod, claude, config_home, scratch_root, redact.Redactor(),
                                        resume=resolve_resume(mod.META, fixtures_root))
            observed = census.census([r["frame"] for r in session.frames() if "frame" in r], help_text=help_text, version=version)
            with open(os.path.join(fpath, "census.json"), encoding="utf-8") as fh:
                recorded = json.load(fh)
            # `meta["deterministic"]`, not `.get`: `census.diff` raises on an unknown mode
            # rather than defaulting, for exactly this reason -- an absent value would quietly
            # relax the strict comparison into the permissive one. The `except` below reports
            # the KeyError as the fixture defect it is.
            lines = census.diff(recorded, observed, "exact" if meta["deterministic"] else "required")
            if census.UNPARSEABLE_PAIR in observed["pairs"]:
                # The other half of the alarm-on-appearance rule. `census.diff` cannot raise
                # this unconditionally: `verify` recounts a fixture's own frames through the
                # same function, and a fixture that legitimately holds one undecodable line
                # would then fail its own recount for a reason that is not true of it. Here,
                # at the live-binary gate, an undecodable line is always worth saying out loud.
                lines = list(lines) + ["%s: %d undecodable stdout line(s) in this run"
                                       % (census.UNPARSEABLE_PAIR, observed["pairs"][census.UNPARSEABLE_PAIR]["count"])]
        except Exception as e:
            # `make probe` is a verdict on every fixture, not on the first one that breaks. A
            # scenario that cannot be re-run at all -- a binary that has moved, a resume whose
            # scratch cwd was cleared, a census file that will not parse -- is itself drift
            # worth reporting, and catching it here is what keeps the other fixtures' verdicts
            # on the screen. It counts against the exit status like any other drift.
            #
            # Redacted, unlike `verify`'s findings: those are safe by construction because they
            # name only a rule and a position, while an arbitrary exception message is not --
            # `load_scenario` alone raises one carrying an absolute path.
            drifted += 1
            report.append(redact.Redactor().redact_text(
                "%s: FAILED to run (%s: %s)" % (n, type(e).__name__, e), record=False))
            continue
        finally:
            os.environ.clear(); os.environ.update(env_backup)
        if lines:
            drifted += 1
            report.append("%s: DRIFT (%d difference%s)" % (n, len(lines), "" if len(lines) == 1 else "s"))
            report += ["  " + l for l in group_drift(lines)]
        else:
            report.append("%s: ok" % n)
    if len(names) - skipped == 0:
        # `make probe` is the headline gate, and a gate that passes because it compared nothing
        # is worse than one that fails: a run before any fixture exists, or a mistyped
        # `AFLEET_FIXTURES_ROOT`, would otherwise report success in silence.
        report.append("no census fixture was compared under %s; this run proves nothing" % fixtures_root)
        return 1, "\n".join(report)
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
        fixture.redact_tree(os.path.join(path, sub), r)
    # `streams.json` holds the byte sizes of the files under `initial/`, so a rule that
    # changed one of them has invalidated every offset in it. Recomputed exactly the way
    # `write_fixture` computes it, from the files as they now stand.
    with open(os.path.join(path, "streams.json"), "w", encoding="utf-8") as fh:
        json.dump(fixture.stream_sizes(os.path.join(path, "initial")), fh, indent=1, sort_keys=True)
    with open(os.path.join(path, "redaction.json"), "w", encoding="utf-8") as fh:
        json.dump(r.manifest(), fh, indent=1, sort_keys=True)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="probe")
    sub = ap.add_subparsers(dest="cmd")
    for name in ("census", "diff", "record", "snapshot", "redact", "verify", "sign", "synthetic"):
        sp = sub.add_parser(name)
        sp.add_argument("--claude", default=None)
        sp.add_argument("--config-home", default=None)
        if name == "census":
            sp.add_argument("--scenario", nargs="*", default=[])
        if name == "diff":
            sp.add_argument("--fixture", default=None); sp.add_argument("--script", default=None)
        if name == "record":
            sp.add_argument("scenario"); sp.add_argument("--reviewer", default=None)
            sp.add_argument("--out", default=None, help="the fixture directory to write (default Fixtures/<name>)")
        if name in ("snapshot", "redact"):
            sp.add_argument("fixture")
        if name == "verify":
            sp.add_argument("fixtures", nargs="+")
            # `verify_fixture` defaults to the local host, which is right where the recording
            # was made. A review elsewhere has to name the recording host or rule 3's hostname
            # half cannot fire at all (spec Revision Note, 2026-09-04).
            sp.add_argument("--hostname", default=None, help="the hostname the fixture was recorded on")
        if name == "sign":
            sp.add_argument("fixture"); sp.add_argument("--reviewer", required=True)
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_usage(); return 2
    if args.cmd == "census":
        out = {}
        for name in ["zero_cost"] + list(args.scenario):
            mod = load_scenario(name)
            # §4.2 qualifies the *named* scenarios with `census: true`; the zero-cost census is
            # the command's own first line rather than a scenario that opts in.
            if name in args.scenario and not mod.META.get("census"):
                log("skipped %s (census: false)" % mod.META["name"]); continue
            argv_b = tool_argv(args.claude, mod.META)
            version, help_text = claude_version(argv_b), claude_help(argv_b)
            session, ctx = run_scenario(mod, args.claude, args.config_home, SCRATCH_ROOT, redact.Redactor(), resume=resolve_resume(mod.META, FIXTURES_ROOT))
            out[mod.META["name"]] = census.census([r["frame"] for r in session.frames() if "frame" in r], help_text=help_text, version=version)
        print(json.dumps(out, indent=1, sort_keys=True)); return 0
    if args.cmd == "diff":
        code, report = diff(args.claude, config_home=args.config_home, only=args.fixture, script=args.script)
        print(report); return code
    if args.cmd == "record":
        path, errors = record(args.scenario, args.claude, config_home=args.config_home, reviewer=args.reviewer, out=args.out)
        print("recorded %s" % path)
        blocking, advisory = classify_errors(errors)
        for e in blocking:
            print("ERROR " + e)
        for e in advisory:
            print("needs review: " + e)
        return 1 if blocking else 0
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
    if args.cmd == "sign":
        sign(args.fixture.rstrip("/"), args.reviewer); print("signed %s" % args.fixture); return 0
    if args.cmd == "synthetic":
        # Rebuilding is deliberately destructive of the two directories it owns: `build`
        # writes each fixture whole through `write_fixture`, so a rebuild drops the review
        # block back to unsigned and the fixture has to be walked and signed again. That is
        # the intended cost -- the frames changed, so the signature no longer covers them.
        from synthetic import dialogs
        for p in dialogs.build(FIXTURES_ROOT):
            print("built %s" % p)
        return 0


if __name__ == "__main__":
    sys.exit(main())
