#!/usr/bin/env bash
set -euo pipefail

# Diagnostic CI only: never attach to the owner's television or media library.
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'Use an isolated GitHub Actions runner.' >&2; exit 2; }
package="${1:?Pass the built standalone render-probe VPKG}"
[[ -f "$package" ]] || { echo 'The render-probe package is missing.' >&2; exit 2; }
package="$(realpath "$package")"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$HOME/vega/env"
cd "$repo"

app_id=com.dineshdevkota.mediavault.renderprobe
evidence="$repo/.artifacts/vega-render-probe/runtime"
mkdir -p "$evidence"
vega exec vpt dump "$package" manifest.toml --dest-path "$evidence/manifest.toml" >/dev/null
python3 - "$evidence/manifest.toml" "$app_id" <<'PY'
import sys, tomllib
from pathlib import Path
manifest = tomllib.loads(Path(sys.argv[1]).read_text())
assert manifest['package']['id'] == sys.argv[2], 'Refusing a non-probe package'
components = manifest['components']['interactive']
assert len(components) == 1 and components[0]['id'] == sys.argv[2] + '.main', 'Unexpected probe component'
PY
sha256sum "$package" >"$evidence/package-sha256.txt"
git rev-parse HEAD >"$evidence/source-sha.txt"
printf '{"sdkPin":"2.0.15159","glAccelerationRequested":false,"standaloneProbe":true}\n' >"$evidence/graphics-mode.json"

appium_pid=''; start_requested=false; virtual_device_verified=false
cleanup() {
  local original_status=$?
  trap - EXIT
  set +e
  if [[ "$virtual_device_verified" == true ]]; then
    # Query only this newly installed probe, with bounded time and retained size.
    timeout --kill-after=2s 15s vega exec vda shell "loggingctl log -v $app_id --since today" 2>&1 |
      tail -c 2097152 >"$evidence/native.log"
  fi
  [[ -z "$appium_pid" ]] || kill "$appium_pid" 2>/dev/null
  if [[ "$start_requested" == true ]]; then
    timeout --kill-after=2s 30s vega virtual-device stop >"$evidence/stop.log" 2>&1
  fi
  exit "$original_status"
}
trap cleanup EXIT
start_requested=true
vega virtual-device start --no-gui --no-gl-accel --timeout 180 >"$evidence/boot.log" 2>&1
vega device info --device VirtualDevice >"$evidence/device.json"
python3 - "$evidence/device.json" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
assert info.get('simulated') is True, 'Refusing a physical device'
assert info.get('architecture') == 'x86_64', 'Unexpected virtual-device architecture'
PY
virtual_device_verified=true
if ! python3 -c 'import json,sys; sys.exit(not json.load(open(sys.argv[1])).get("inDeveloperMode", False))' "$evidence/device.json"; then
  vega exec vda shell 'vsm developer-mode enable'
  ready=false
  for attempt in {1..60}; do
    if vega device info --device VirtualDevice >"$evidence/device.json" 2>/dev/null &&
       python3 -c 'import json,sys; i=json.load(open(sys.argv[1])); sys.exit(not (i.get("simulated") is True and i.get("architecture") == "x86_64" and i.get("inDeveloperMode") is True))' "$evidence/device.json"; then
      ready=true; break
    fi
    sleep 2
  done
  [[ "$ready" == true ]] || { echo 'The virtual device did not finish restarting.' >&2; exit 1; }
fi
vega exec vda shell 'touch /tmp/automation-toolkit.enable'
timeout --kill-after=2s 60s vega run-app "$package" "$app_id.main" -d VirtualDevice >"$evidence/launch.log" 2>&1
export PATH="$(dirname "$(vega exec which vda)"):$PATH"
# The driver logs raw RPC bodies outside Appium's logger. Retain only its
# filtered warning log, consistent with the full isolated fixture runner.
appium --address 127.0.0.1 --log-level warn --log "$evidence/appium.log" >/dev/null 2>&1 &
appium_pid=$!
for attempt in {1..60}; do
  if curl --fail --silent http://127.0.0.1:4723/status >/dev/null; then break; fi
  kill -0 "$appium_pid" 2>/dev/null || { echo 'Appium exited before becoming ready.' >&2; exit 1; }
  sleep 1
done
curl --fail --silent http://127.0.0.1:4723/status >/dev/null

probe_status=0
APPIUM_URL=http://127.0.0.1:4723 PROBE_DEVICE_INFO="$evidence/device.json" PROBE_OUTPUT="$evidence"   timeout --kill-after=2s 180s node tools/vega/render-probe/render-probe.mjs || probe_status=$?
# Analyze whatever was captured even if native focus or the harness failed;
# preserve that original failure as the job outcome.
analysis_status=0
python3 tools/vega/render-probe/analyze-pixels.py "$evidence" || analysis_status=$?
printf '{"harnessExitCode":%s,"analysisExitCode":%s}\n' "$probe_status" "$analysis_status" >"$evidence/runner-result.json"
[[ "$probe_status" == 0 ]] || exit "$probe_status"
exit "$analysis_status"
