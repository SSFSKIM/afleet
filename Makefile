PYTHON ?= python3
CLAUDE ?= claude
FIXTURE ?=
SCENARIO ?=
SCRIPT ?=
REVIEWER ?=

.PHONY: test-tools probe census record redact verify-fixtures synthetic sign

# The fake-claude suite is empty until its task lands; exit 5 is 3.12+'s "no tests ran",
# which is not a failure here. A missing start directory still fails (ImportError).
test-tools:
	$(PYTHON) -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_*.py'
	$(PYTHON) -m unittest discover -s Tools/fake-claude/tests -t Tools/fake-claude/tests -p 'test_*.py' || test $$? -eq 5

probe:
	$(PYTHON) Tools/probe/probe.py diff --claude "$(CLAUDE)" $(if $(FIXTURE),--fixture "$(FIXTURE)") $(if $(SCRIPT),--script "$(SCRIPT)")

census:
	$(PYTHON) Tools/probe/probe.py census --claude "$(CLAUDE)"

record:
	@test -n "$(SCENARIO)" || (echo "usage: make record SCENARIO=<name>" && exit 2)
	$(PYTHON) Tools/probe/probe.py record "$(SCENARIO)" --claude "$(CLAUDE)"

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
