# MediaVault deployment preparation

The community source currently builds MediaVault 1.5.0, build 7. Keep each
platform's package identifier and signing identity for updates. Compare the
build number with the last accepted build in each store before signing.

| Target | Package to prepare | Release identity |
| --- | --- | --- |
| Android phone and Android TV | Android App Bundle | `com.dineshdevkota.cinevault` |
| Android-based Amazon Fire TV | Android release APK or AAB for the selected Appstore track | `com.dineshdevkota.cinevault` |
| Vega-based Amazon Fire TV | ARMv7 Release VPKG | `com.dineshdevkota.cinevault` |
| iPhone | Signed iOS archive | `com.dineshdevkota.cinevault.ios` |
| Apple TV | Signed tvOS archive | `com.dineshdevkota.cinevault` |

GitHub Actions retains the community unsigned Android AAB, unsigned Android and
Fire OS APK, three Vega release packages, and unsigned Apple device apps. Use the
Vega ARMv7 artifact for physical-device qualification. The aarch64 and x86_64
builds are for virtual-device compatibility. The Apple app ZIPs and Android
unsigned files are staging artifacts. A store submission uses the appropriate
production signing and distribution workflow.

## Android phone, Android TV, and Fire OS

From `android/`, the community release command is:

```bash
./gradlew --no-daemon :core:test :app:testDebugUnitTest :app:lintRelease :app:assembleRelease :app:bundleRelease
```

The outputs are in `app/build/outputs/apk/release/` and
`app/build/outputs/bundle/release/`. The shared app targets Android API 36 and
supports Android-based Fire TV back to API 22. The release excludes the opt-in
Android NFS native libraries. The [Android guide](ANDROID.md) describes the
existing protected signing settings. Use the original signer for updates to
an existing Fire OS or directly installed app and the authorized upload key
for Play App Signing. Supply the signing environment outside the repository.
For a signed APK that supports API 22, check the signature on all declared API
levels with `apksigner verify --min-sdk-version 22 --verbose <apk>`.

In Play Console, supply a public privacy-policy URL, Data safety and age-rating
answers, screenshots, review access, and Android TV distribution metadata.
Verify the phone launcher and the TV banner, D-pad focus, source setup, seek,
subtitles, and household access on physical devices. In Amazon Developer Console,
select the Fire TV device targets and provide the TV listing artwork, review
access, and policy disclosures for the supported Fire OS and Vega packages.
Use synthetic or licensed demo media with both stores.
[Google Play publishing](https://developer.android.com/studio/publish)
· [Android TV quality](https://developer.android.com/docs/quality-guidelines/tv-app-quality)
· [Google Play User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311)
· [Amazon Appstore submission](https://developer.amazon.com/docs/app-submission/submitting-apps-to-amazon-appstore.html)

## Vega

On a supported Linux host with the pinned Vega SDK, set the intended next build
number in `vega/manifest.toml` and run `bash tools/vega/build.sh armv7 Release`.
Use the production VPKG and its package and license evidence. Validate the
package on a supported physical Fire TV Stick with the same release identity.
Exercise protected storage, PIN and credential persistence after restart,
source access, remote focus, and native media playback and seeking. Virtual
fixtures verify the synthetic library and guarded startup. The simulator cannot
verify the production Vega keystore.
[Fire TV build and test guide](FIRE-TV.md)
· [Amazon Vega submission](https://developer.amazon.com/docs/vega/2.0/app-submission)
· [Vega Crypto API](https://developer.amazon.com/docs/vega-api/2.0/README.amazon-devices_keplercrypto)

## iPhone and Apple TV

Generate the iPhone project with `xcodegen generate --spec project.ios.yml`.
Generate the Apple TV project with `xcodegen generate --spec project.yml`.
The Apple workflows build the Release app for `generic/platform=iOS` and
`generic/platform=tvOS`, verify the bundled policy and privacy manifest, and
record the unsigned app's build identity and checksum.

An authorized Apple Developer team needs to choose the App Store Connect app
record arrangement, sign and validate both archives, verify the release-only
settings on physical devices, and supply policy, screenshots and reviewer
access. See the [Apple App Review handoff](APPLE-APP-REVIEW.md) for exact review
steps, privacy and transport checks, and provider registration requirements.
