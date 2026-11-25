#!/usr/bin/env bash
set -euo pipefail

# This script must never attach to the owner's TV or reuse their library.
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'Use the isolated GitHub Actions runner.' >&2; exit 2; }
package="${1:?Pass the built x86_64 VPKG}"
[[ -f "$package" && "$package" == *x86_64*.vpkg ]] || { echo 'An x86_64 package is required.' >&2; exit 2; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$HOME/vega/env"
cd "$repo"
evidence="$repo/.artifacts/vega-ui"
mkdir -p "$evidence"
nas_pid=''; appium_pid=''; log_device_serial=''
cleanup() {
  if [[ -n "$log_device_serial" && "$log_device_serial" != unknown ]]; then
    # Collect only this app on the verified disposable device, retaining its
    # latest 2 MiB. Time is bounded even if a native service or VDA is stuck.
    # https://developer.amazon.com/docs/vega/2.0/loggingctl documents -v.
    timeout --kill-after=2s 15s vega exec vda -s "$log_device_serial" shell 'loggingctl log -v com.dineshdevkota.cinevault' 2>&1 |
      tail -c 2097152 >"$evidence/device-application.log" || true
  fi
  [[ -z "$appium_pid" ]] || kill "$appium_pid" 2>/dev/null || true
  [[ -z "$nas_pid" ]] || kill "$nas_pid" 2>/dev/null || true
  vega virtual-device stop >"$evidence/stop.log" 2>&1 || true
}
trap cleanup EXIT
vega virtual-device start --no-gui --no-gl-accel --timeout 180 >"$evidence/boot.log" 2>&1
vega device info --device VirtualDevice >"$evidence/device.json"
python3 - "$evidence/device.json" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
assert info.get('simulated') is True, 'Refusing to test on a physical device'
assert info.get('architecture') == 'x86_64', 'Unexpected virtual-device architecture'
PY
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
# Developer mode can restart VDA. Resolve its serial only after that restart,
# retaining bounded lookup diagnostics instead of silently omitting app logs.
for attempt in {1..3}; do
  if timeout --kill-after=2s 15s vega exec vda get-serialno >"$evidence/device-serial.txt" 2>>"$evidence/device-serial.log"; then
    candidate="$(tr -d '\r\n' <"$evidence/device-serial.txt")"
    if [[ "$candidate" =~ ^emulator-[0-9]+$ ]]; then log_device_serial="$candidate"; break; fi
  fi
  sleep 1
done
if [[ -z "$log_device_serial" ]]; then
  printf 'The verified virtual device did not provide a usable VDA serial.\n' >"$evidence/device-application.log"
fi
vega exec vda shell 'touch /tmp/automation-toolkit.enable'
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
vega run-app "$package" com.dineshdevkota.cinevault.main -d VirtualDevice >"$evidence/launch.log" 2>&1
export PATH="$(dirname "$(vega exec which vda)"):$PATH"
# Debug-level driver logs include text-entry request bodies. Keep diagnostics
# without retaining the synthetic password/PIN values from these journeys.
appium --address 127.0.0.1 --log-level warn --log "$evidence/appium.log" >"$evidence/appium-console.log" 2>&1 &
appium_pid=$!
for attempt in {1..60}; do
  if curl --fail --silent http://127.0.0.1:4723/status >/dev/null; then break; fi
  sleep 1
done
curl --fail --silent http://127.0.0.1:4723/status >/dev/null
export MEDIA_VAULT_E2E_FIXTURE_ONLY=1
export MEDIA_VAULT_E2E_NAS_ENDPOINT=smb://127.0.0.1:1445/MEDIALIBRARY
export MEDIA_VAULT_E2E_OUTPUT="$evidence"
node vega/e2e/library-journey.mjs
