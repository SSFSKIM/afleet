"""The wiring check's own gate: does it actually catch a member the app never calls?

Same reasoning as the drift checker's test. A check that reports clean is read as evidence,
and the two defects this one exists to catch — `PanelHostModel.selectIndex(_:in:)` and
`ChannelTimelineRegistry.release(_:)`, both correct, both tested, both with no production
caller — were found by hand while the suite stayed green. So it is run against known-bad
trees rather than trusted on inspection.

Each case writes a tiny `App/` and `AppTests/` pair into a temporary directory, points the
checker's roots at it, and asserts on the count it reports. Nothing here touches the
repository; the real tree is exercised once, at the end, as the check the merge runs.
"""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
CHECKER = ROOT / "Tools/c5/check-app-wiring.py"

spec = importlib.util.spec_from_file_location("check_app_wiring", CHECKER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WiringCheckTests(unittest.TestCase):

    def run_against(self, app: str, tests: str, allowlist: dict[str, str] | None = None) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "App").mkdir()
            (root / "AppTests").mkdir()
            (root / "App/Thing.swift").write_text(app)
            (root / "AppTests/ThingTests.swift").write_text(tests)
            module.APP = root / "App"
            module.TESTS = root / "AppTests"
            saved = module.ALLOWLIST
            if allowlist is not None:
                module.ALLOWLIST = allowlist
            try:
                findings = module.findings()
            finally:
                module.ALLOWLIST = saved
            return [name for name, _, _ in findings]

    def test_a_member_only_the_tests_call_is_a_finding(self):
        app = "struct Thing {\n    func onlyTested() {}\n    func used() { }\n    func caller() { used() }\n}\n"
        tests = "func t() { Thing().onlyTested() }\n"
        self.assertEqual(self.run_against(app, tests), ["onlyTested"])

    def test_a_member_the_app_calls_is_not(self):
        app = "struct Thing {\n    func wired() {}\n    func caller() { wired() }\n}\n"
        tests = "func t() { Thing().wired() }\n"
        self.assertEqual(self.run_against(app, tests), [])

    def test_a_member_nobody_calls_is_not(self):
        """Unexercised production code is a coverage question. This check is about wiring."""
        app = "struct Thing {\n    func lonely() {}\n}\n"
        self.assertEqual(self.run_against(app, "func t() {}\n"), [])

    def test_a_doc_comment_is_not_a_call_site(self):
        app = "struct Thing {\n    /// Calls onlyTested() when it feels like it.\n    func onlyTested() {}\n}\n"
        tests = "func t() { Thing().onlyTested() }\n"
        self.assertEqual(self.run_against(app, tests), ["onlyTested"])

    def test_a_string_literal_is_not_a_call_site(self):
        app = 'struct Thing {\n    func onlyTested() {}\n    func log() { print("onlyTested") }\n}\n'
        tests = "func t() { Thing().onlyTested() }\n"
        self.assertEqual(self.run_against(app, tests), ["onlyTested"])

    def test_an_interpolation_inside_a_literal_is_a_call_site(self):
        """The inverse of the case above, and the one the first version of the stripper got wrong."""
        app = 'struct Thing {\n    var counted: Int { 1 }\n    func log() { print("n: \\(counted)") }\n}\n'
        tests = "func t() { _ = Thing().counted }\n"
        self.assertEqual(self.run_against(app, tests), [])

    def test_the_allowlist_exempts_and_nothing_else_does(self):
        app = "struct Thing {\n    func onlyTested() {}\n}\n"
        tests = "func t() { Thing().onlyTested() }\n"
        self.assertEqual(self.run_against(app, tests, allowlist={"onlyTested": "a reason"}), [])
        self.assertEqual(self.run_against(app, tests, allowlist={"somethingElse": "a reason"}),
                         ["onlyTested"])

    def test_the_repository_is_clean(self):
        result = subprocess.run([sys.executable, str(CHECKER)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
