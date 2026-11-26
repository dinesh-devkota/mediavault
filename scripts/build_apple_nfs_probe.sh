#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  "") host_only=false ;;
  --host-only) host_only=true ;;
  *) echo "Usage: $0 [--host-only]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [--host-only]" >&2
  exit 2
fi

if [[ "$host_only" == false && "$(uname -s)" != Darwin ]]; then
  echo "Use macOS with Xcode for tvOS checks, or pass --host-only." >&2
  exit 2
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/mediavault-apple-nfs.XXXXXX")"
trap 'rm -rf "$work"' EXIT
source="$work/libnfs-source"
archive="$work/libnfs-5.0.3.tar.gz"
checksum=d945cb4f4c8f82ee1f3640893a168810f794a28e1010bb007ec5add345e9df3e

if [[ -n "${NFS_SOURCE_ARCHIVE:-}" ]]; then
  cp "$NFS_SOURCE_ARCHIVE" "$archive"
else
  curl --fail --silent --show-error --location \
    https://codeload.github.com/sahlberg/libnfs/tar.gz/refs/tags/libnfs-5.0.3 -o "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check
mkdir "$source"
tar -xzf "$archive" --strip-components=1 -C "$source"
patch -d "$source" -p1 -i "$repo/android/native-nfs/nfs3-no-follow-opendir.patch"

build_probe() {
  local build="$1"
  shift
  cmake -G "Unix Makefiles" -S "$repo/scripts/apple-nfs" -B "$build" \
    -DLIBNFS_SOURCE="$source" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"
  cmake --build "$build" --target nfs_readonly_probe --parallel 2
}

build_probe "$work/host"
NFS_PROBE="$work/host/nfs_readonly_probe" PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest discover -v -s "$repo/scripts/tests" -p test_nfs_readonly_probe.py

if [[ "$host_only" == true ]]; then
  exit 0
fi

build_tvos_probe() {
  local sdk="$1"
  local platform="$2"
  local build="$work/$sdk"
  local probe="$build/nfs_readonly_probe.app/nfs_readonly_probe"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  build_probe "$build" -DCMAKE_SYSTEM_NAME=tvOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0
  xcrun lipo "$probe" -verify_arch arm64
  local build_version
  build_version="$(xcrun vtool -show-build "$probe")"
  printf '%s\n' "$build_version"
  if ! grep -Eq "^[[:space:]]*platform[[:space:]]+$platform[[:space:]]*$" <<< "$build_version"; then
    echo "Expected Mach-O platform $platform for $sdk." >&2
    return 1
  fi
}

build_tvos_probe appletvos TVOS
build_tvos_probe appletvsimulator TVOSSIMULATOR
