#!/usr/bin/env bash
set -euo pipefail

# This fixture journey writes a synthetic source to a fresh CI installation.
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "This runner requires a disposable GitHub Actions emulator." >&2
  exit 1
fi
SERIAL=$(adb devices | awk '$1 ~ /^emulator-/ && $2 == "device" { print $1 }')
if [[ -z "$SERIAL" || "$SERIAL" == *$'\n'* || "$(adb -s "$SERIAL" shell getprop ro.kernel.qemu | tr -d '\r')" != "1" ]]; then
  echo "Expected exactly one disposable Android emulator." >&2
  exit 1
fi
export ANDROID_SERIAL="$SERIAL"
PLEX_CERTIFICATE=$(base64 -w0 "$RUNNER_TEMP/phone-plex/fixture.cer")
PHONE_CASES=com.dineshdevkota.cinevault.AndroidPhoneNavigationTest
PLEX_CASES=com.dineshdevkota.cinevault.plex.PlexTlsIntegrationTest
cd android
./gradlew --no-daemon --max-workers=4 :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class="$PHONE_CASES,$PLEX_CASES" \
  -Pandroid.testInstrumentationRunnerArguments.nasHost=10.0.2.2 \
  -Pandroid.testInstrumentationRunnerArguments.plexCertificate="$PLEX_CERTIFICATE" \
  -Pandroid.testInstrumentationRunnerArguments.phoneUiFixture=true
python3 - <<'PY'
from pathlib import Path
from xml.etree import ElementTree

reports = Path("app/build/outputs/androidTest-results").rglob("TEST-*.xml")
cases = [case for report in reports for case in ElementTree.parse(report).getroot().iter("testcase")]
expected = {
    "handheldLauncherOpensSourceFormAndShowsAddressValidation",
    "touchSetupImportsMovieAndPlaysAndSeeksWithNativeControls",
    "touchNavigationOpensPlexLinking",
    "ownerConnectsOverTlsAndReadsCatalogAndMediaRange",
}
if len(cases) != len(expected) or {case.get("name") for case in cases} != expected:
    raise SystemExit("All phone checks must execute on exactly one emulator.")
if any(case.find(tag) is not None for case in cases for tag in ("failure", "error", "skipped")):
    raise SystemExit("Phone runtime journeys failed or skipped.")
print(f"Android phone: {len(cases)} touch and Plex playback checks passed.")
PY
