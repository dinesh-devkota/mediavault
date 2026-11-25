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
cd android
status=0
./gradlew --no-daemon --max-workers=4 :app:connectedDebugAndroidTest \
  -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true \
  -Pandroid.testInstrumentationRunnerArguments.class=com.dineshdevkota.cinevault.AndroidPhoneNavigationTest,com.dineshdevkota.cinevault.LibraryFeaturesNavigationTest,com.dineshdevkota.cinevault.library.LocalLibraryIntegrationTest,com.dineshdevkota.cinevault.playback.SmbPlaybackTest#mkvPlaybackAndSeekFromNas \
  -Pandroid.testInstrumentationRunnerArguments.nasHost=10.0.2.2 \
  -Pandroid.testInstrumentationRunnerArguments.libraryUiFixture=true \
  -Pandroid.testInstrumentationRunnerArguments.phoneUiFixture=true || status=$?
mkdir -p app/build/phone-screenshots
adb -s "$SERIAL" pull /sdcard/Android/data/com.dineshdevkota.cinevault/files/test-artifacts/. app/build/phone-screenshots/ || true
if [[ "$status" != "0" ]]; then exit "$status"; fi
test -s app/build/phone-screenshots/library-version-picker-phone.png
test -s app/build/phone-screenshots/library-custom-collection-phone.png
python3 - <<'PY'
from pathlib import Path
from xml.etree import ElementTree

reports = Path("app/build/outputs/androidTest-results").rglob("TEST-*.xml")
cases = [case for report in reports for case in ElementTree.parse(report).getroot().iter("testcase")]
expected = {
    "handheldLauncherOpensSourceFormAndShowsAddressValidation",
    "touchSetupImportsMovieAndPlaysAndSeeksWithNativeControls",
    "localArtworkVersionsAndNamedCollectionsUseNativeControls",
    "importsRealNasSidecarsGroupsVersionsAndDecodesLocalArtWithoutKey",
    "customCollectionsPersistButNeverCrossHouseholdProfilesOrRevealRestrictedFranchises",
    "mkvPlaybackAndSeekFromNas",
    "invalidSidecarsClearOldRatingButTemporaryReadFailurePreservesIt",
}
if len(cases) != len(expected) or {case.get("name") for case in cases} != expected:
    raise SystemExit("Every required phone library, playback and touch journey must execute on exactly one emulator.")
if any(case.find(tag) is not None for case in cases for tag in ("failure", "error", "skipped")):
    raise SystemExit("Phone runtime journeys failed or skipped.")
print(f"Android phone: {len(cases)} library, playback and touch journeys passed.")
PY
