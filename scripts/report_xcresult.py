"""Report completed XCTest results and fail closed when validation did not run."""

import argparse
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


def report_suite(path, suite):
    def cases(nodes, in_suite=False):
        for node in nodes:
            matches = in_suite or node.get("name") == suite
            if matches and node.get("nodeType") == "Test Case":
                yield node
            yield from cases(node.get("children", []), matches)

    try:
        results = json.loads(Path(path).read_text(encoding="utf-8"))
        executed = list(cases(results["testNodes"]))
    except (AttributeError, OSError, ValueError, KeyError, TypeError) as error:
        annotation(f"Missing or invalid XCTest case results: {error}")
        return 1

    if not executed or any(case.get("result") != "Passed" for case in executed):
        annotation(f"Required suite {suite} did not execute successfully.")
        return 1
    print(f"Required suite {suite}: {len(executed)} test(s) passed.")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary")
    parser.add_argument("--require-suite", nargs=2, metavar=("RESULTS_JSON", "SUITE"))
    arguments = parser.parse_args()
    result = report(arguments.summary)
    if result == 0 and arguments.require_suite:
        result = report_suite(*arguments.require_suite)
    sys.exit(result)
