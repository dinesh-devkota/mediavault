# MediaVault on Amazon Fire TV

Fire TV includes two different operating systems. MediaVault uses its shared
Android app for Fire OS and a separate Vega app for Vega OS. An Android APK does
not run on Vega. Amazon documents both families in its [Fire TV overview](https://developer.amazon.com/apps-and-games/fire-tv).

## Fire OS build

The Fire TV branch targets Android API 22 and later, covering Fire OS 5, 6, 7, 8 and
later Android-based releases. It recognizes Amazon's `amazon.hardware.fire_tv`
feature as well as the normal TV UI mode, so the remote interface is selected
without changing the phone layout. No Google Play Services are required.

Older devices use Android Keystore-protected credential encryption. Existing
API 23+ stored credentials retain their original format and key alias. Older
Fire OS devices also get compatible PIN hashing, photo decoding and player
lifecycle handling. The remote's transport keys continue working while a header
button has focus.

Local app/test APK builds and lint pass. The dedicated hosted workflow passed
13 tests each on API 22, 25 and 28 for credential persistence/tampering, household PINs, photos,
local metadata, MKV playback, seeking, remote controls and background/resume.
The modern Android TV run passed 110 tests and the phone run passed seven UI
journeys. These are Android API compatibility tests, not physical Fire TV certification.
Real-device codec, memory and Wi-Fi performance must also be checked before
Appstore submission. Older hardware may not decode newer codecs.

For developer installation, use the same Android APK and follow Amazon's
[ADB setup](https://developer.amazon.com/docs/fire-tv/connecting-adb-to-device).
Keep the same signing key when updating an existing installation to preserve
its data. Do not clear the app's data to install an update.

## Vega build in progress

The separate `vega/` application targets Vega OS 2 and React Native 0.83. Amazon
states that OS 2 has rolled out to all Vega-powered Fire TV devices; normal
firmware updates are required. See the [OS 2 release notes](https://developer.amazon.com/docs/vega/2.0/vega-release-notes).

The actual published SDK is pinned to 2.0.15159. `tools/vega/Dockerfile` builds an
isolated Ubuntu host with pinned base images and a verified official installer.
Source development includes SMB, WebDAV and Jellyfin, local metadata/artwork,
profile-scoped collections, versions, photos, continuous viewing and protected
source access. The native SMB/HTTP/credential bridge compiles against Amazon's
real SDK. TypeScript checking, 42 app/contract tests and 74 native host regression
tests pass. The host suite exercises real SMB/HTTPS fixtures, including rejected
credentials, cancellation, certificate verification and Jellyfin access boundaries.
All three production release architectures (armv7, aarch64 and x86_64) pass
Amazon's manifest and binary-interface validation, with their Hermes interface
bundle and both native libraries present. The latest package checks passed at
`96073fa` in run `45730914333`. Runtime validation is still in progress; do not
describe Vega as released or device-verified yet. Host tests do not exercise the
device keystore.

The SMB sign-in stall found by the negative-credential tests is fixed. Connection
negotiation and authentication have a ten-second deadline and support cancellation;
upstream system DNS resolution can still take longer. The build selects the final
VPKG explicitly instead of counting the SDK's staging copy twice.
On the virtual device, production startup reports `MV06:not-supported` from
the native keystore. Amazon explicitly documents that its
[Crypto API is unsupported in the simulator](https://developer.amazon.com/docs/vega-api/2.0/README.amazon-devices_keplercrypto).
Production keeps the library closed when protected storage is unavailable.

A separately identified Debug/x86_64 test package uses in-memory synthetic
credentials so the remaining interface and playback can be exercised. Its native
code permits only the three fixed loopback NAS fixtures and refuses external
HTTP access. CMake refuses this storage for release builds, device architectures,
or the production package identity. The packaged binary is checked for a fixture
marker, which must be absent from every release. This isolated package passes the
actual SDK manifest/ABI checks; its UI journeys remain under hosted validation.
The 74 host checks include 17 fixture-policy/build-guard tests. Another 20 tests
verify staging and packaged identities, and seven validate the startup probe.
None of these replace physical-device secure-storage and restart testing.

Production startup probes in runs `45726677998` and `45728952472` confirmed the
exact unsupported-storage state, hidden library and enabled Retry. The fixture
app opened NAS setup and accepted text. Test automation now reads the real input
editor, navigates with the remote, and dismisses only the observed SDK Debug
warning overlay. No complete library journey has passed yet.

The player waits for the native video surface before opening a
stream, reads real player state when optional events are absent, and explicitly
permits the internal `127.0.0.1` HTTP media relay. Other HTTP destinations remain
disallowed. Confirmed malformed local metadata now clears uncertain age ratings
even when another sidecar is temporarily unavailable, matching the Apple policy.
Valid subtitles survive malformed or oversized neighboring subtitle files.
Collection posters open normally even when home bulk selection remains active.

The initial Vega app still lacks the existing Android/Apple apps' TMDB settings,
SubDL downloads, automatic NAS discovery and editing an existing household profile.
The original Android APK, including those features, is used on Fire OS.

The visible title is MediaVault. Its internal package ID deliberately matches the
existing Android ID (`com.dineshdevkota.cinevault`) so Amazon can associate the Fire
OS and Vega variants. Changing the installed Android identity would break updates.

Amazon supports [cloud/Docker builds](https://developer.amazon.com/docs/vega/2.0/continuous-integration).
Windows is not an officially supported native SDK host. Docker is used for
compilation only; Amazon does not support VVD inside Docker. The hosted workflow
runs virtual-device tests directly on Linux with hardware acceleration and an
isolated synthetic NAS. Store publication and physical-device developer mode
require the owner's Amazon Developer account; no store upload is part of these
build checks.

## Reproduce the Vega checks

On a supported Linux host, install Node 22 and the documented SDK prerequisites,
then run `bash tools/vega/install-sdk.sh`. Run
`bash tools/vega/build.sh aarch64 Release` for the first architecture; `armv7` and
`x86_64` use the same command. The script builds the native module, builds the app,
validates the package and verifies that both the native bridge and SMB shared
library are present. It does not publish an app or configure an owner account.

`.github/workflows/vega.yml` builds all three release architectures, verifies
production startup separately, and runs nine real Appium library/player journeys
with the visibly marked simulator fixture app. Its tenth journey, credential
persistence, is explicitly skipped as hardware-required. See
[`vega/e2e/README.md`](../vega/e2e/README.md) for the distinct result formats.
The runtime script refuses to attach
to a physical TV or run outside the isolated cloud job. It forwards a synthetic
loopback NAS explicitly; it does not scan the owner's network or use their media.
Screenshots, UI trees and test results are retained even on failure. A pending or
failed workflow is not evidence of Vega runtime compatibility.

Native dependency sources and license notices are documented in
[`vega/THIRD-PARTY-NOTICES.md`](../vega/THIRD-PARTY-NOTICES.md). Keep those notices
and the exact LGPL source with any eventual distributed package.
