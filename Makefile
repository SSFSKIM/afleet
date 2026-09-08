PYTHON ?= python3
CLAUDE ?= claude
FIXTURE ?=
SCENARIO ?=
SCRIPT ?=
REVIEWER ?=

.PHONY: test-tools probe census record redact verify-fixtures synthetic sign spike check-x7 check-wiring

# The fake-claude suite is empty until its task lands; exit 5 is 3.12+'s "no tests ran",
# which is not a failure here. A missing start directory still fails (ImportError).
test-tools:
	$(PYTHON) -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_*.py'
	$(PYTHON) -m unittest discover -s Tools/fake-claude/tests -t Tools/fake-claude/tests -p 'test_*.py' || test $$? -eq 5
	$(PYTHON) -m unittest discover -s Tools/c5/tests -t Tools/c5/tests -p 'test_*.py'
	$(MAKE) check-x7
	$(MAKE) check-wiring

probe:
	$(PYTHON) Tools/probe/probe.py diff --claude "$(CLAUDE)" $(if $(FIXTURE),--fixture "$(FIXTURE)") $(if $(SCRIPT),--script "$(SCRIPT)")

census:
	$(PYTHON) Tools/probe/probe.py census --claude "$(CLAUDE)"

record:
	@test -n "$(SCENARIO)" || (echo "usage: make record SCENARIO=<name>" && exit 2)
	$(PYTHON) Tools/probe/probe.py record "$(SCENARIO)" --claude "$(CLAUDE)"

# The spikes of §4.7 whose answer is a finding rather than a recording. Runs the scenario and
# prints its notes; nothing under Fixtures/ is touched.
spike:
	@test -n "$(SCENARIO)" || (echo "usage: make spike SCENARIO=<name>" && exit 2)
	$(PYTHON) Tools/probe/probe.py spike "$(SCENARIO)" --claude "$(CLAUDE)"

# Re-runs the §4.5 rules over a committed fixture, in place and idempotently, and rewrites
# the manifest. FIXTURE is the fixture directory, not its name.
redact:
	@test -n "$(FIXTURE)" || (echo "usage: make redact FIXTURE=Fixtures/<name>" && exit 2)
	$(PYTHON) Tools/probe/probe.py redact "$(FIXTURE)"

verify-fixtures:
	$(PYTHON) Tools/probe/probe.py verify Fixtures/*/

# Rebuilds both synthetic dialog fixtures (spec §4.7) from their schemas. It replaces the two
# directories whole, signature included, so each rebuild has to be reviewed and signed again.
synthetic:
	$(PYTHON) Tools/probe/probe.py synthetic

# The human half of the gate: run it only after walking Fixtures/REVIEW.md for the fixture.
sign:
	@test -n "$(FIXTURE)" -a -n "$(REVIEWER)" || (echo "usage: make sign FIXTURE=Fixtures/<name> REVIEWER=<name>" && exit 2)
	$(PYTHON) Tools/probe/probe.py sign "$(FIXTURE)" --reviewer "$(REVIEWER)"

# --- The app ---------------------------------------------------------------
# `afleet.xcodeproj` is generated, so every target that needs it regenerates it first.

.PHONY: generate build test check-imports live

SCHEME ?= afleet
DESTINATION ?= platform=macOS
ONLY ?=

# --- Getting a switch to the test host -------------------------------------
#
# `xcodebuild` hands the test host **none** of the invoking shell's environment. A variable
# reaches it only when it is spelled `TEST_RUNNER_<NAME>`; the runner re-exports it with the
# prefix stripped. Measured on Xcode 26.6: with `AFLEET_LIVE_CLI=1` in the shell the host sees
# nothing, with `TEST_RUNNER_AFLEET_LIVE_CLI=1` it sees `AFLEET_LIVE_CLI=1`. An unprefixed
# switch therefore does not fail — the gated test *skips*, and a skip reads as a pass, which is
# the failure mode this forwarding exists to close.
#
# So every switch a suite in this tree reads is translated here when it is set in make's
# environment, and an operator who asks for live gets live. `swift test` and the Python suites
# inherit the environment as usual and need no translation.
TEST_SWITCHES := AFLEET_LIVE_CLI AFLEET_LIVE_CLI_TURNS AFLEET_LOCAL_INDEX AFLEET_SPIKE_C5_2 \
                 CLAUDE_CONFIG_DIR
TEST_RUNNER_ENV = $(foreach v,$(TEST_SWITCHES),$(if $($(v)),TEST_RUNNER_$(v)="$($(v))"))

# The one config home the live legs run under (spec §7.8, X9): never the user's.
SCRATCH_HOME ?= $(or $(CLAUDE_CONFIG_DIR),/tmp/afleet-fixtures/config-home)
# What `make live` runs. C5's G1e by default: one unprompted `claude`, zero model turns.
LIVE_ONLY ?= AfleetTests/LiveForeignChannelTests

generate:
	xcodegen generate

build: generate
	xcodebuild -scheme $(SCHEME) -configuration Debug build

# The app's suites and every package suite in one invocation, then the Python tools.
#
# `-test-timeouts-enabled` is a watchdog, not an instrument. Every wait inside a test in this tree
# is fulfilled by the event it waits for and none of them has a deadline, which is the rule — but a
# *broken* implementation can then leave a wait unfulfilled for ever, and an XCTest run has no
# per-test limit of its own. Task 6 watched exactly that: a deliberately mutated model held the
# suite at 100 percent of one core for eleven minutes with no output. The allowance turns that into
# a reported failure. It bounds the harness; it decides no assertion.
test: generate
	env $(TEST_RUNNER_ENV) xcodebuild test -scheme $(SCHEME) -destination '$(DESTINATION)' \
		$(if $(ONLY),-only-testing:$(ONLY)) \
		-test-timeouts-enabled YES -default-test-execution-time-allowance 120
	$(MAKE) test-tools

# The live legs, run deliberately and never silently.
#
# Every precondition the gate would otherwise *skip* on is checked here first and fails loudly,
# because a skipped live gate that exits zero is indistinguishable from a live gate that passed —
# which is exactly how a gate gets signed on evidence nobody produced. Nothing here writes under a
# config home: the scratch home is read, and only the `claude` the test spawns writes into it.
live: generate
	@test -d "$(SCRATCH_HOME)" || { \
		echo "make live: no scratch config home at $(SCRATCH_HOME); the live legs run under that home and nowhere else"; \
		exit 2; }
	@command -v $(CLAUDE) >/dev/null 2>&1 || { \
		echo "make live: no '$(CLAUDE)' on PATH; the live legs spawn the installed engine"; exit 2; }
	@$(PYTHON) -c "import json,sys; d=json.load(open('$(SCRATCH_HOME)/.claude.json')); sys.exit(0 if d.get('hasCompletedOnboarding') else 1)" 2>/dev/null || { \
		echo "make live: the scratch config home reports no completed onboarding; recover with one interactive run by hand under CLAUDE_CONFIG_DIR pointed at it"; \
		exit 2; }
	env TEST_RUNNER_AFLEET_LIVE_CLI=1 TEST_RUNNER_CLAUDE_CONFIG_DIR="$(SCRATCH_HOME)" \
		$(foreach v,AFLEET_LIVE_CLI_TURNS AFLEET_LOCAL_INDEX,$(if $($(v)),TEST_RUNNER_$(v)="$($(v))")) \
		xcodebuild test -scheme $(SCHEME) -destination '$(DESTINATION)' -only-testing:$(LIVE_ONLY) \
		-test-timeouts-enabled YES -default-test-execution-time-allowance 300

# Contract X1 over the app target, alone.
check-imports: generate
	xcodebuild test -scheme $(SCHEME) -destination '$(DESTINATION)' -only-testing:AfleetTests/ImportGraphTests

# Does the shipped X7 protocol still match what the documents declare? C5's Task 2 review found
# the same drift three times — a signature changed in code and left stale in a document another
# child copies from — so it is checked mechanically rather than by reading. Needs no Xcode.
check-x7:
	$(PYTHON) Tools/c5/check-x7-drift.py

# Tracker entry 72: a member declared in `App/` whose only callers are in `AppTests/`. Two defects
# in one C5 review cycle had that shape — correct, tested, and never on the path the app takes —
# and both were found by hand. Needs no Xcode.
check-wiring:
	$(PYTHON) Tools/c5/check-app-wiring.py
