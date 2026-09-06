"""The drift checker's own gate: does it actually catch a drifted signature?

The first version of `check-x7-drift.py` reported clean against four of five injected drifts,
including a member silently losing its `async` — the exact defect it was written to catch. A
guard that reports clean because it found nothing is worse than no guard, because it is read as
evidence. So the checker is not trusted on inspection; it is run against known-bad documents.

Each case edits C5's plan — the canonical Code block every later child copies from — one
declaration at a time, runs the checker, and restores the file. The plan is written back in a
`finally` so a failing assertion cannot leave the repository modified.
"""
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
CHECKER = ROOT / "Tools/c5/check-x7-drift.py"
PLAN = ROOT / "docs/doperpowers/plans/2026-09-06-c5-app-shell.md"

# (label, line as the plan currently has it, line as the drift would leave it).
# `None` for the replacement means the declaration is deleted outright, which is the other way a
# document goes stale: a member is added to the code and the block is never extended.
INJECTIONS = [
    ("select gains async",
     "    func select(_ id: PanelTabID)\n",
     "    func select(_ id: PanelTabID) async\n"),
    ("popOut gains async",
     "    func popOut(_ id: PanelTabID, channel: ChannelKey)\n",
     "    func popOut(_ id: PanelTabID, channel: ChannelKey) async\n"),
    ("register gains async",
     "    func register(_ tab: any PanelTab) throws\n",
     "    func register(_ tab: any PanelTab) async throws\n"),
    ("available gains async",
     "    func available(for context: ChannelContext) -> [PanelTabID]\n",
     "    func available(for context: ChannelContext) async -> [PanelTabID]\n"),
    ("run loses async",
     "    func run(_ request: PaneRequest) async throws\n",
     "    func run(_ request: PaneRequest) throws\n"),
    ("popOut is deleted",
     "    func popOut(_ id: PanelTabID, channel: ChannelKey)\n",
     None),
]


def run_checker():
    return subprocess.run([sys.executable, str(CHECKER)], cwd=ROOT,
                          capture_output=True, text=True)


class CheckX7DriftTests(unittest.TestCase):

    def test_the_unmodified_documents_are_clean(self):
        """The floor. Without it every injection below could be failing for some other reason."""
        result = run_checker()
        self.assertEqual(result.returncode, 0,
                         f"the checker does not pass against the documents as they stand:\n"
                         f"{result.stdout}{result.stderr}")

    def test_the_source_walk_accounts_for_every_shipped_requirement(self):
        """The printed count must mean coverage, not "what the parser happened to find"."""
        swift = sorted((ROOT / "Workbench/Sources/PanelHostAPI").glob("*.swift"))
        self.assertTrue(swift, "no sources to walk")
        result = run_checker()
        reported = int(result.stdout.split("X7 drift check: ")[1].split(" requirements")[0])
        # Every `func` or `var` line indented inside a protocol body in the real sources.
        declared = 0
        for path in swift:
            inside = False
            for line in path.read_text().splitlines():
                if "protocol " in line and line.rstrip().endswith("{"):
                    inside = True
                elif line.startswith("}"):
                    inside = False
                elif inside and line.strip().startswith(("func ", "var ")):
                    declared += 1
        self.assertEqual(reported, declared,
                         "the checker's member count is not the number of requirements the "
                         "target declares")

    def test_every_injected_drift_is_caught(self):
        original = PLAN.read_text()
        undetected = []
        try:
            for label, before, after in INJECTIONS:
                self.assertEqual(original.count(before), 1,
                                 f"{label}: the plan no longer contains the line this case edits, "
                                 f"so the case proves nothing")
                PLAN.write_text(original.replace(before, after if after is not None else ""))
                result = run_checker()
                if result.returncode == 0:
                    undetected.append(f"{label} (checker exited 0)")
                elif "DRIFT" not in result.stdout:
                    undetected.append(f"{label} (non-zero exit but no DRIFT line)")
        finally:
            PLAN.write_text(original)
        self.assertEqual(undetected, [],
                         "the checker reported clean against these injected drifts: "
                         + ", ".join(undetected))
        self.assertEqual(PLAN.read_text(), original, "the plan was not restored")


if __name__ == "__main__":
    unittest.main()
