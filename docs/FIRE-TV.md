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

Local app/test APK builds and lint pass. The dedicated hosted workflow checks
API 22,25 and28 for credential persistence/tampering, household PINs, photos,
local metadata, MKV playback, seeking, remote controls and background/resume.
These are Android API compatibility tests, not physical Fire TV certification.
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
Source development includes local metadata/artwork, profile-scoped collections,
versions, photos, continuous viewing and protected source access. The native
SMB/HTTP/credential bridge and packaged runtime validation are still in progress;
do not describe Vega as released or verified yet.

Amazon supports [cloud/Docker builds](https://developer.amazon.com/docs/vega/2.0/continuous-integration).
Windows is not an officially supported native SDK host. Build and virtual-device
checks therefore use Linux. Store publication and physical-device developer mode
require the owner's Amazon Developer account; no store upload is part of these
build checks.
