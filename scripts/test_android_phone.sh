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
app_id=com.dineshdevkota.cinevault
phone_class="$app_id.AndroidPhoneNavigationTest"
plex_class="$app_id.plex.PlexTlsIntegrationTest"
drive_class="$app_id.playback.SmbPlaybackTest"
drive_tree="googleDriveFolderImportPhotosCaptionsAndSeekRequireAnExplicitHouseholdGrant"
drive_files="googleDriveExplicitDocumentsCannotReadAnUnselectedFile"
cd android
status=0
./gradlew --no-daemon --max-workers=4 :app:connectedDebugAndroidTest \
  "-Pandroid.testInstrumentationRunnerArguments.class=$phone_class,$plex_class,$drive_class#$drive_tree,$drive_class#$drive_files" \
  -Pandroid.testInstrumentationRunnerArguments.nasHost=10.0.2.2 \
  -Pandroid.testInstrumentationRunnerArguments.plexCertificate="$PLEX_CERTIFICATE" \
  -Pandroid.testInstrumentationRunnerArguments.phoneUiFixture=true || status=$?
python3 - "$phone_class" "$plex_class" "$drive_class" "$drive_tree" "$drive_files" <<'PY'
from pathlib import Path
from sys import argv
from xml.etree import ElementTree

reports = Path("app/build/outputs/androidTest-results").rglob("TEST-*.xml")
cases = [case for report in reports for case in ElementTree.parse(report).getroot().iter("testcase")]
phone, plex, drive, tree, files = argv[1:]
expected = {
    (phone, "handheldLauncherOpensSourceFormAndShowsAddressValidation"),
    (phone, "touchSetupImportsMovieAndPlaysAndSeeksWithNativeControls"),
    (phone, "touchEditsAndRemovesAnExistingGoogleDriveSelection"),
    (phone, "touchNavigationOpensPlexLinking"),
    (plex, "ownerConnectsOverTlsAndReadsCatalogAndMediaRange"),
    (drive, tree),
    (drive, files),
}
executed = {(case.get("classname"), case.get("name")) for case in cases}
problems = 0
for case in cases:
    outcome = next((tag for tag in ("failure", "error", "skipped") if case.find(tag) is not None), "passed")
    print(f"{case.get('classname')}.{case.get('name')} {outcome}")
    if outcome != "passed":
        problems += 1
        problem = case.find(outcome)
        print((problem.text or problem.get("message") or outcome)[:2500])
if len(cases) != len(expected) or executed != expected:
    raise SystemExit("The phone fixture tests must execute on exactly one emulator.")
if problems:
    raise SystemExit("Phone runtime tests failed or skipped.")
print(f"Android phone: {len(cases)} runtime tests passed.")
PY
exit "$status"
