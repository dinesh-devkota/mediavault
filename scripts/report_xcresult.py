"""Report completed XCTest results and fail closed when validation did not run."""

import json
import os
import sys
from pathlib import Path


COUNT_KEYS = ("totalTestCount", "passedTests", "failedTests", "skippedTests")


def annotation(message):
    escaped = str(message)[:4000].replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::error title=XCTest simulator tests::{escaped}")


def report(path):
    try:
        summary = json.loads(Path(path).read_text(encoding="utf-8"))
        counts = {key: summary[key] for key in COUNT_KEYS}
        if any(type(value) is not int or value < 0 for value in counts.values()):
            raise ValueError("test counts must be nonnegative integers")
    except (OSError, ValueError, KeyError, TypeError) as error:
        annotation(f"Missing or invalid XCTest summary: {error}")
        return 1

    message = "XCTest simulator tests: " + json.dumps(counts, sort_keys=True)
    print(message)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
            output.write(message + "\n")

    for failure in summary.get("testFailures", []):
        annotation(failure.get("testName", "") + ": " + failure.get("failureText", ""))
    if counts["totalTestCount"] != counts["passedTests"] + counts["failedTests"] + counts["skippedTests"]:
        annotation("Inconsistent XCTest counts: total must equal passed + failed + skipped.")
        return 1
    if counts["totalTestCount"] == 0 or counts["passedTests"] + counts["failedTests"] == 0:
        annotation("No tests executed; a skipped or missing test run cannot pass validation.")
        return 1
    if counts["skippedTests"]:
        annotation(f"{counts['skippedTests']} test(s) skipped; this fixture suite requires every test to run.")
        return 1
    if counts["failedTests"]:
        annotation(f"{counts['failedTests']} test(s) failed.")
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: report_xcresult.py SUMMARY_JSON")
    sys.exit(report(sys.argv[1]))
