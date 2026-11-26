#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 ]]; then
  printf 'Usage: %s ios|tvos APP_BUNDLE DESTINATION\n' "$0" >&2
  exit 2
fi
platform=$1
app_bundle=$2
destination=$3
case "$platform" in
  ios) expected_sdk=iphoneos; expected_id=com.dineshdevkota.cinevault.ios ;;
  tvos) expected_sdk=appletvos; expected_id=com.dineshdevkota.cinevault ;;
  *) printf 'Use ios or tvos for the device release platform.\n' >&2; exit 2 ;;
esac

info="$app_bundle/Info.plist"
property() { plutil -extract "$1" raw -o - "$info"; }
bundle_id=$(property CFBundleIdentifier)
sdk_name=$(property DTPlatformName)
executable=$(property CFBundleExecutable)
if [[ $bundle_id != "$expected_id" || $sdk_name != "$expected_sdk" ||
      $(property CFBundleDisplayName) != MediaVault || ! -x "$app_bundle/$executable" ||
      -e "$app_bundle/embedded.mobileprovision" ]]; then
  printf 'Expected the unsigned MediaVault %s device app with bundle ID %s.\n' "$platform" "$expected_id" >&2
  exit 1
fi
version=$(property CFBundleShortVersionString)
build=$(property CFBundleVersion)
if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $build =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  printf 'Expected the three-part release version and numeric build number.\n' >&2
  exit 1
fi

mkdir -p "$destination"
archive="MediaVault-${platform}-${version}-${build}-unsigned.app.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$destination/$archive"
unzip -tq "$destination/$archive"
(
  cd "$destination"
  shasum -a 256 "$archive" > SHA256SUMS.txt
)
printf 'commit %s\nplatform %s\nbundle-id %s\nversion %s\nbuild %s\n' \
  "$(git rev-parse HEAD)" "$platform" "$bundle_id" "$version" "$build" > "$destination/BUILD.txt"
