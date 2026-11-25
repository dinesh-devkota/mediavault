#!/usr/bin/env bash
set -euo pipefail

# This journey intentionally creates household controls. It is only for the
# disposable GitHub Actions emulator, never an owner's installed app.
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "This runner requires a disposable GitHub Actions emulator." >&2
  exit 1
fi
RESULTS="${RUNNER_TEMP:?}/android-runtime-results"
APP_ID="com.dineshdevkota.cinevault"
FAMILY_TEST="${APP_ID}.FamilyNavigationTest"
SERIAL=$(adb devices | awk '$1 ~ /^emulator-/ && $2 == "device" { print $1 }')
if [[ -z "$SERIAL" || "$SERIAL" == *$'\n'* || "$(adb -s "$SERIAL" shell getprop ro.kernel.qemu | tr -d '\r')" != "1" ]]; then
  echo "Expected exactly one disposable Android emulator." >&2
  exit 1
fi
export ANDROID_SERIAL="$SERIAL"
mkdir -p "$RESULTS/baseline" "$RESULTS/family"
cd android

archive_results() {
  local suite="$1"
  test -d app/build/outputs/androidTest-results
  test ! -e "$RESULTS/$suite/androidTest-results"
  # Moving the completed outputs both retains evidence and makes the next Gradle
  # invocation create fresh reports, so the two phases cannot be double-counted.
  mv app/build/outputs/androidTest-results "$RESULTS/$suite/"
  if [[ -d app/build/reports/androidTests ]]; then
    mv app/build/reports/androidTests "$RESULTS/$suite/"
  fi
  python3 - "$RESULTS/$suite/androidTest-results" "$suite" "$FAMILY_TEST" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
root, phase, family = sys.argv[1:]
cases = [case for report in Path(root).rglob("TEST-*.xml")
         for case in ET.parse(report).getroot().iter("testcase")]
identities = [(case.get("classname"), case.get("name")) for case in cases]
if not cases or len(set(identities)) != len(cases) or any(not all(item) for item in identities):
    raise SystemExit(f"{phase}: missing, unnamed or duplicate executed test evidence")
if any(case.find(tag) is not None for case in cases for tag in ("failure", "error", "skipped")):
    raise SystemExit(f"{phase}: failed or skipped runtime test")
if phase == "baseline" and any(name == family for name, _ in identities):
    raise SystemExit("Household journey must not execute during baseline tests")
if phase == "family" and any(name != family for name, _ in identities):
    raise SystemExit("Household report contains tests from another phase")
print(f"{phase}: {len(cases)} executed tests verified")
PY
}

status=0
./gradlew --no-daemon --max-workers=4 :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.nasHost=10.0.2.2 \
  "-Pandroid.testInstrumentationRunnerArguments.notClass=$FAMILY_TEST" || status=$?
archive_results baseline
if [[ "$status" != "0" ]]; then exit "$status"; fi

# The baseline suite uses shared synthetic app data. The household journey starts
# from an empty app and checks that condition itself before creating any profile.
if [[ "$(adb -s "$SERIAL" shell pm clear "$APP_ID" | tr -d '\r')" != "Success" ]]; then
  echo "Could not prepare the isolated household fixture." >&2
  exit 1
fi
status=0
./gradlew --no-daemon --max-workers=4 :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.nasHost=10.0.2.2 \
  "-Pandroid.testInstrumentationRunnerArguments.class=$FAMILY_TEST" \
  -Pandroid.testInstrumentationRunnerArguments.familyUiFixture=true || status=$?
archive_results family
if [[ "$status" != "0" ]]; then exit "$status"; fi
adb -s "$SERIAL" pull "/sdcard/Android/data/$APP_ID/files/test-artifacts" "$RESULTS/screenshots"
test -s "$RESULTS/screenshots/family-profile-picker.png"
test -s "$RESULTS/screenshots/family-admin-permissions.png"
