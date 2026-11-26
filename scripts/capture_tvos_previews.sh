#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 DEVICE APP OUTPUT_DIRECTORY" >&2
  exit 2
fi

DEVICE="$1"
APP="$2"
RUNNER_TEMP="$3"

# Verify the exact spelling independently of OCR's all-caps word spacing.
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$APP/Info.plist")" == "MediaVault" ]]
swiftc scripts/verify_preview.swift -o "$RUNNER_TEMP/verify-preview"
capture_when_ready() {
  local path="$1"
  shift
  local expected="$*"
  for attempt in {1..24}; do
    if ! kill -0 "$PID" 2>/dev/null; then
      echo "CineVault exited before $expected became visible." >&2
      return 1
    fi
    if xcrun simctl io "$DEVICE" screenshot "$path" >/dev/null 2>&1 &&
       "$RUNNER_TEMP/verify-preview" "$path" "$@"; then
      sleep 15
      if kill -0 "$PID" 2>/dev/null &&
         xcrun simctl io "$DEVICE" screenshot "$path" >/dev/null 2>&1 &&
         "$RUNNER_TEMP/verify-preview" "$path" "$@"; then
        return 0
      fi
    fi
    sleep 5
  done
  echo "Timed out waiting for $expected in the screenshot." >&2
  return 1
}
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"
LAUNCH=$(xcrun simctl launch "$DEVICE" com.dineshdevkota.cinevault --ui-preview)
echo "$LAUNCH"
PID="${LAUNCH##*: }"
capture_when_ready "$RUNNER_TEMP/cinevault-home.png" "Welcome to MediaVault" "Continue Watching" "Next available" "S01E03" "See all"
xcrun simctl terminate "$DEVICE" com.dineshdevkota.cinevault
LAUNCH=$(xcrun simctl launch "$DEVICE" com.dineshdevkota.cinevault --ui-preview-detail)
echo "$LAUNCH"
PID="${LAUNCH##*: }"
capture_when_ready "$RUNNER_TEMP/cinevault-detail.png" "Start Over" "Midnight Horizon"
xcrun simctl terminate "$DEVICE" com.dineshdevkota.cinevault
LAUNCH=$(xcrun simctl launch "$DEVICE" com.dineshdevkota.cinevault --ui-preview-filters)
PID="${LAUNCH##*: }"
capture_when_ready "$RUNNER_TEMP/cinevault-filters.png" "All Genres" "Adventure" "Drama" "Apply"
xcrun simctl terminate "$DEVICE" com.dineshdevkota.cinevault
LAUNCH=$(xcrun simctl launch "$DEVICE" com.dineshdevkota.cinevault --ui-preview-nas)
PID="${LAUNCH##*: }"
capture_when_ready "$RUNNER_TEMP/cinevault-nas.png" "Devices on your network"
xcrun simctl terminate "$DEVICE" com.dineshdevkota.cinevault
LAUNCH=$(xcrun simctl launch "$DEVICE" com.dineshdevkota.cinevault --ui-preview-nas-folder)
PID="${LAUNCH##*: }"
capture_when_ready "$RUNNER_TEMP/cinevault-nas-folder.png" "Living Room NAS" "Use this folder & scan"
xcrun simctl terminate "$DEVICE" com.dineshdevkota.cinevault
LAUNCH=$(xcrun simctl launch "$DEVICE" com.dineshdevkota.cinevault --ui-preview-photos)
PID="${LAUNCH##*: }"
capture_when_ready "$RUNNER_TEMP/cinevault-photos.png" "Photos" "Summer Trip" "Family NAS"
xcrun simctl terminate "$DEVICE" com.dineshdevkota.cinevault
LAUNCH=$(xcrun simctl launch "$DEVICE" com.dineshdevkota.cinevault --ui-preview-photo)
PID="${LAUNCH##*: }"
capture_when_ready "$RUNNER_TEMP/cinevault-photo.png" "Golden Hour" "Next" "Back"
xcrun simctl terminate "$DEVICE" com.dineshdevkota.cinevault
LAUNCH=$(xcrun simctl launch "$DEVICE" com.dineshdevkota.cinevault --ui-preview-search)
PID="${LAUNCH##*: }"
capture_when_ready "$RUNNER_TEMP/cinevault-search.png" "Search" "1 result" "192 episodes"
