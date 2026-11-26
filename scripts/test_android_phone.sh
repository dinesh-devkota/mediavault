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
DROPBOX_FIXTURE="${RUNNER_TEMP:?}/android-phone-dropbox"
bash scripts/start_dropbox_fixture.sh "$DROPBOX_FIXTURE"
DROPBOX_PID=$(cat "$DROPBOX_FIXTURE/server.pid")
trap 'kill "$DROPBOX_PID" 2>/dev/null || true' EXIT
DROPBOX_CERTIFICATE=$(openssl base64 -A -in "$DROPBOX_FIXTURE/fixture.cer")
APP_ID="com.dineshdevkota.cinevault"
PHONE_TEST="$APP_ID.AndroidPhoneNavigationTest"
PLEX_CASES="$APP_ID.plex.PlexTlsIntegrationTest"
DROPBOX_MEDIA="$APP_ID.playback.SmbPlaybackTest#dropboxApprovalImportPlaybackSeekPhotosAndHouseholdGate"
PLEX_CERTIFICATE=$(base64 -w0 "$RUNNER_TEMP/phone-plex/fixture.cer")
CLASSES="$PHONE_TEST,$PLEX_CASES,$DROPBOX_MEDIA,$APP_ID.cloud.OneDriveSetupNavigationTest,$APP_ID.cloud.OneDriveMediaIntegrationTest,$APP_ID.cloud.OneDriveAccountStoreInstrumentedTest"
cd android
status=0
./gradlew --no-daemon --max-workers=4 :app:connectedDebugAndroidTest \
  "-Pandroid.testInstrumentationRunnerArguments.class=$CLASSES" \
  "-Pandroid.testInstrumentationRunnerArguments.dropboxCertificate=$DROPBOX_CERTIFICATE" \
  -Pandroid.testInstrumentationRunnerArguments.nasHost=10.0.2.2 \
  "-Pandroid.testInstrumentationRunnerArguments.plexCertificate=$PLEX_CERTIFICATE" \
  -Pandroid.testInstrumentationRunnerArguments.phoneUiFixture=true || status=$?
python3 - <<'PY'
from pathlib import Path
from xml.etree import ElementTree

reports = Path("app/build/outputs/androidTest-results").rglob("TEST-*.xml")
cases = [case for report in reports for case in ElementTree.parse(report).getroot().iter("testcase")]
expected = {
    "handheldLauncherOpensSourceFormAndShowsAddressValidation",
    "touchSetupImportsMovieAndPlaysAndSeeksWithNativeControls",
    "touchNavigationOpensPlexLinking",
    "touchNavigationOpensOneDriveSetupAlongsidePlex",
    "ownerConnectsOverTlsAndReadsCatalogAndMediaRange",
    "ownerCanOpenOneDriveSetupAndRecoverFromInvalidPublicApplicationId",
    "stagedSignInImportsSelectedFolderAndPlaysWithBoundedReadsAndCaptions",
    "refreshRecordIsEncryptedOnDiskAndRemovable",
    "dropboxApprovalImportPlaybackSeekPhotosAndHouseholdGate",
}
failures = 0
for case in cases:
    outcome = next((tag for tag in ("failure", "error", "skipped") if case.find(tag) is not None), "passed")
    print(f"{case.get('classname')}.{case.get('name')} {outcome}")
    failures += outcome != "passed"
if len(cases) != len(expected) or {case.get("name") for case in cases} != expected:
    raise SystemExit("Every expected phone runtime test must execute on exactly one emulator.")
if failures:
    raise SystemExit("Phone runtime journeys failed or skipped.")
print(f"Android phone: {len(cases)} runtime tests passed.")
PY

exit "$status"
