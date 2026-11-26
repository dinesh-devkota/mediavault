#!/usr/bin/env bash
set -euo pipefail

# This script must never attach to the owner's TV or reuse their library.
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'Use the isolated GitHub Actions runner.' >&2; exit 2; }
gl_accel="${MEDIA_VAULT_VVD_GL_ACCEL-0}"
case "$gl_accel" in
  0) graphics_args=(--no-gl-accel); graphics_enabled=false ;;
  1) graphics_args=(); graphics_enabled=true ;; # Use the pinned SDK's default graphics acceleration.
  *) echo 'MEDIA_VAULT_VVD_GL_ACCEL must be 0 or 1.' >&2; exit 2 ;;
esac
package="${1:?Pass the built x86_64 VPKG}"
[[ -f "$package" && "$package" == *x86_64*.vpkg ]] || { echo 'An x86_64 package is required.' >&2; exit 2; }
fixture_package="${2:?Pass the separate simulator-only VPKG}"
[[ -f "$fixture_package" ]] || { echo 'The isolated fixture package is required.' >&2; exit 2; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$HOME/vega/env"
cd "$repo"
evidence="$repo/.artifacts/vega-ui"
mkdir -p "$evidence"
printf '{"glAccelerationRequested":%s,"sdkDefaultGraphics":%s}\n' "$graphics_enabled" "$graphics_enabled" >"$evidence/graphics-mode.json"
bash tools/vega/check-package.sh "$package" production x86_64 >"$evidence/production-package-validation.json"
bash tools/vega/check-package.sh "$fixture_package" fixture x86_64 >"$evidence/fixture-package-validation.json"
nas_pid=''; appium_pid=''; fixture_log_pid=''; virtual_device_verified=false
cleanup() {
  [[ -z "$fixture_log_pid" ]] || kill "$fixture_log_pid" 2>/dev/null || true
  if [[ "$virtual_device_verified" == true ]]; then
    # LoggingCtl resolves access from already-installed apps. Query after the
    # journeys (before stopping the disposable device), including stored logs
    # from this fresh boot. A pre-install stream cannot see either new package.
    for app_id in com.dineshdevkota.cinevault com.dineshdevkota.mediavault.vvdfixture; do
      timeout --kill-after=2s 15s vega exec vda shell "loggingctl log -v $app_id --since today" 2>&1 |
        tail -c 2097152 >"$evidence/$app_id.log" || true
    done
  fi
  [[ -z "$appium_pid" ]] || kill "$appium_pid" 2>/dev/null || true
  [[ -z "$nas_pid" ]] || kill "$nas_pid" 2>/dev/null || true
  vega virtual-device stop >"$evidence/stop.log" 2>&1 || true
}
trap cleanup EXIT
vega virtual-device start --no-gui "${graphics_args[@]}" --timeout 180 >"$evidence/boot.log" 2>&1
vega device info --device VirtualDevice >"$evidence/device.json"
python3 - "$evidence/device.json" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
assert info.get('simulated') is True, 'Refusing to test on a physical device'
assert info.get('architecture') == 'x86_64', 'Unexpected virtual-device architecture'
PY
virtual_device_verified=true
if ! python3 -c 'import json,sys; sys.exit(not json.load(open(sys.argv[1])).get("inDeveloperMode", False))' "$evidence/device.json"; then
  vega exec vda shell 'vsm developer-mode enable'
  # Enabling developer mode reboots only this disposable virtual device.
  ready=false
  for attempt in {1..60}; do
    if vega device info --device VirtualDevice >"$evidence/device.json" 2>/dev/null &&
       python3 -c 'import json,sys; i=json.load(open(sys.argv[1])); sys.exit(not (i.get("simulated") is True and i.get("inDeveloperMode") is True))' "$evidence/device.json"; then
      ready=true; break
    fi
    sleep 2
  done
  [[ "$ready" == true ]] || { echo 'The virtual device did not finish restarting.' >&2; exit 1; }
fi
vega exec vda shell 'touch /tmp/automation-toolkit.enable'
vega run-app "$package" com.dineshdevkota.cinevault.main -d VirtualDevice >"$evidence/production-launch.log" 2>&1
export PATH="$(dirname "$(vega exec which vda)"):$PATH"
# Amazon's driver prints raw JSON-RPC bodies directly to stdout even when the
# Appium log level is warn. Keep only the filtered logger file, never that raw
# stream, so synthetic password/PIN entry is not copied into retained artifacts.
appium --address 127.0.0.1 --log-level warn --log "$evidence/appium.log" >/dev/null 2>&1 &
appium_pid=$!
for attempt in {1..60}; do
  if curl --fail --silent http://127.0.0.1:4723/status >/dev/null; then break; fi
  sleep 1
done
curl --fail --silent http://127.0.0.1:4723/status >/dev/null
export MEDIA_VAULT_E2E_FIXTURE_ONLY=1
MEDIA_VAULT_E2E_PACKAGE_ID=com.dineshdevkota.cinevault \
  MEDIA_VAULT_E2E_STARTUP_CHECK_ONLY=1 \
  MEDIA_VAULT_E2E_OUTPUT="$evidence/production-startup" \
  node vega/e2e/library-journey.mjs
# The production probe remains separate evidence. Never reinterpret the
# simulator's unsupported keystore as successful library/persistence testing.
vega device terminate-app --device VirtualDevice --appName com.dineshdevkota.cinevault.main >"$evidence/production-stop.log" 2>&1
python3 scripts/nas_fixture.py "$RUNNER_TEMP/vega-nas" >"$evidence/nas.log" 2>&1 &
nas_pid=$!
python3 - <<'PY'
import socket, time
for _ in range(40):
    try:
        with socket.create_connection(('127.0.0.1', 1445), timeout=1):
            break
    except OSError:
        time.sleep(1)
else:
    raise SystemExit('Synthetic NAS did not start')
PY
vega exec vda reverse tcp:1445 tcp:1445
vega run-app "$fixture_package" com.dineshdevkota.mediavault.vvdfixture.main -d VirtualDevice >"$evidence/fixture-launch.log" 2>&1
# Start after installation so LoggingCtl has permission to see this package.
# Following now retains initial focus/render diagnostics before a noisy native
# input loop pushes them out of the default end-of-run snapshot.
timeout --kill-after=2s 1200s vega exec vda shell \
  'loggingctl log -v com.dineshdevkota.mediavault.vvdfixture --since today --follow' \
  >"$evidence/fixture-live.log" 2>&1 &
fixture_log_pid=$!
export MEDIA_VAULT_E2E_PACKAGE_ID=com.dineshdevkota.mediavault.vvdfixture
export MEDIA_VAULT_E2E_STARTUP_CHECK_ONLY=0
export MEDIA_VAULT_E2E_NAS_ENDPOINT=smb://127.0.0.1:1445/MEDIALIBRARY
export MEDIA_VAULT_E2E_OUTPUT="$evidence/fixture"
node vega/e2e/library-journey.mjs
