import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "report_xcresult.py"


class XCTestReportTests(unittest.TestCase):
    def run_report(self, content):
        with tempfile.TemporaryDirectory() as directory:
            result_file = Path(directory) / "summary.json"
            output_file = Path(directory) / "step-summary.md"
            if content is not None:
                result_file.write_text(content, encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(result_file)], capture_output=True,
                text=True, check=False, env={**os.environ, "GITHUB_STEP_SUMMARY": str(output_file)},
            )
            return result, output_file.read_text(encoding="utf-8") if output_file.exists() else ""

    def summary(self, passed=160, failed=0, skipped=0):
        return {"totalTestCount": passed + failed + skipped, "passedTests": passed,
                "failedTests": failed, "skippedTests": skipped}

    def test_completed_tests_report_exact_counts(self):
        result, output = self.run_report(json.dumps(self.summary()))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('"passedTests": 160', output)
        self.assertIn(output.strip(), result.stdout)

    def test_missing_malformed_and_incomplete_summaries_fail(self):
        for content in (None, "", "not json", "{}", "[]", '{"totalTestCount": "160"}'):
            with self.subTest(content=content):
                result, _ = self.run_report(content)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Missing or invalid XCTest summary", result.stdout)

    def test_empty_or_entirely_skipped_run_cannot_pass(self):
        for summary in (self.summary(passed=0), self.summary(passed=0, skipped=160)):
            with self.subTest(summary=summary):
                result, _ = self.run_report(json.dumps(summary))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("No tests executed", result.stdout)

    def test_failure_remains_failure_even_if_runner_exit_was_lost(self):
        summary = self.summary(passed=159, failed=1)
        summary["testFailures"] = [{"testName": "Playback", "failureText": "Failed\n100%"}]
        result, output = self.run_report(json.dumps(summary))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('"failedTests": 1', output)
        self.assertIn("Failed%0A100%25", result.stdout)

    def test_inconsistent_totals_cannot_pass(self):
        for total, passed in ((160, 1), (159, 160)):
            with self.subTest(total=total, passed=passed):
                summary = self.summary(passed=passed)
                summary["totalTestCount"] = total
                result, _ = self.run_report(json.dumps(summary))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Inconsistent XCTest counts", result.stdout)

    def test_partial_skip_cannot_pass_fixture_validation(self):
        result, output = self.run_report(json.dumps(self.summary(passed=159, skipped=1)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('"skippedTests": 1', output)
        self.assertIn("requires every test to run", result.stdout)


if __name__ == "__main__":
    unittest.main()
