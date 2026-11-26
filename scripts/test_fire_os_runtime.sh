#!/usr/bin/env bash
set -euo pipefail
# Never run destructive fixture setup against an owner's installed device.
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "This runner requires a disposable GitHub Actions emulator." >&2
  exit 1
fi
SERIAL=$(adb devices | awk '$1 ~ /^emulator-/ && $2 == "device" { print $1 }')
if [[ -z "$SERIAL" || "$SERIAL" == *$'\n'* || "$(adb -s "$SERIAL" shell getprop ro.kernel.qemu | tr -d '\r')" != "1" ]]; then
  echo "Expected one disposable emulator." >&2
  exit 1
fi
export ANDROID_SERIAL="$SERIAL"
PLEX_CERTIFICATE=$(base64 -w0 "$RUNNER_TEMP/fire-plex/fixture.cer")
cd android
mkdir -p app/build/fire-os-evidence
adb shell getprop ro.build.version.sdk > app/build/fire-os-evidence/android-api.txt
status=0
./gradlew --no-daemon --max-workers=4 :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.dineshdevkota.cinevault.FireOsCompatibilityTest,com.dineshdevkota.cinevault.data.SecretBoxInstrumentedTest,com.dineshdevkota.cinevault.playback.FireOsPlaybackTest,com.dineshdevkota.cinevault.library.LocalLibraryIntegrationTest,com.dineshdevkota.cinevault.playback.SmbPlaybackTest#mkvPlaybackAndSeekFromNas,com.dineshdevkota.cinevault.plex.PlexProviderInstrumentedTest,com.dineshdevkota.cinevault.plex.PlexTlsIntegrationTest \
  -Pandroid.testInstrumentationRunnerArguments.nasHost=10.0.2.2 \
  -Pandroid.testInstrumentationRunnerArguments.plexCertificate="$PLEX_CERTIFICATE" || status=$?
adb logcat -d > app/build/fire-os-evidence/logcat.txt || true
if [[ "$status" != "0" ]]; then exit "$status"; fi
python3 - <<'PY'
from pathlib import Path
from xml.etree import ElementTree
cases = [case for report in Path("app/build/outputs/androidTest-results").rglob("TEST-*.xml")
         for case in ElementTree.parse(report).getroot().iter("testcase")]
expected = {
    "fireFeatureEnablesRemoteLayoutWithoutChangingPhoneLayout",
    "pinAndHouseholdProtectionSurviveRestart",
    "keystoreSecretsPersistRejectTamperingAndNeverRecreateMissingKeys",
    "legacyEnvelopesRemainReadableAlongsideNativeSecrets",
    "legacyPhotoDecodePreservesRotationAndRechecksHiddenState",
    "desugaredFilenameAndSecureXmlParsingWorkOnOldPlatforms",
    "remoteTransportAndLifecycleResumeTheSameNasMovie",
    "importsRealNasSidecarsGroupsVersionsAndDecodesLocalArtWithoutKey",
    "customCollectionsPersistButNeverCrossHouseholdProfilesOrRevealRestrictedFranchises",
    "invalidSidecarsClearOldRatingButTemporaryReadFailurePreservesIt",
    "mkvPlaybackAndSeekFromNas",
    "savesOnlyKeystoreCiphertextAndClearsTheSelectedServer",
    "selectedServerCatalogDecodesAndReadsAnExactRange",
    "ownerConnectsOverTlsAndReadsCatalogAndMediaRange",
}
if len(cases) < 16 or not expected.issubset({case.get("name") for case in cases}):
    raise SystemExit("Required Fire OS compatibility journeys did not all execute.")
if any(case.find(tag) is not None for case in cases for tag in ("failure", "error", "skipped")):
    raise SystemExit("Compatibility checks failed or skipped.")
print(f"Android API compatibility: {len(cases)} tests passed. Physical Fire TV checks remain separate.")
PY
