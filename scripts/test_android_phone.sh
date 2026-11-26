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
app_id=com.dineshdevkota.cinevault
phone_class="$app_id.AndroidPhoneNavigationTest"
library_classes="$app_id.LibraryFeaturesNavigationTest,$app_id.library.LocalLibraryIntegrationTest"
media_class="$app_id.playback.SmbPlaybackTest"
plex_class="$app_id.plex.PlexTlsIntegrationTest"
onedrive_classes="$app_id.cloud.OneDriveSetupNavigationTest,$app_id.cloud.OneDriveMediaIntegrationTest,$app_id.cloud.OneDriveAccountStoreInstrumentedTest"
metadata_class="$app_id.metadata.MetadataMutationTest"
metadata_cases="$metadata_class#plexManualMovieMatchKeepsTheRatingUpdatedWhileItsReplyWasPending,$metadata_class#plexManualTvMatchPreservesRestrictedAndUnknownServerRatings,$metadata_class#plexResetAndAutomaticMetadataCannotDiscardServerIdentityOrClassification"
classes="$phone_class,$library_classes,$media_class#mkvPlaybackAndSeekFromNas,$plex_class,$onedrive_classes,$metadata_cases,$media_class#dropboxApprovalImportPlaybackSeekPhotosAndHouseholdGate"
PLEX_CERTIFICATE=$(base64 -w0 "$RUNNER_TEMP/phone-plex/fixture.cer")
cd android
status=0
./gradlew --no-daemon --max-workers=4 :app:connectedDebugAndroidTest \
  -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true \
  "-Pandroid.testInstrumentationRunnerArguments.class=$classes" \
  "-Pandroid.testInstrumentationRunnerArguments.dropboxCertificate=$DROPBOX_CERTIFICATE" \
  -Pandroid.testInstrumentationRunnerArguments.nasHost=10.0.2.2 \
  -Pandroid.testInstrumentationRunnerArguments.plexCertificate="$PLEX_CERTIFICATE" \
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
    "touchNavigationOpensPlexLinking",
    "touchNavigationOpensOneDriveSetupAlongsidePlex",
    "ownerConnectsOverTlsAndReadsCatalogAndMediaRange",
    "plexManualMovieMatchKeepsTheRatingUpdatedWhileItsReplyWasPending",
    "plexManualTvMatchPreservesRestrictedAndUnknownServerRatings",
    "plexResetAndAutomaticMetadataCannotDiscardServerIdentityOrClassification",
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
