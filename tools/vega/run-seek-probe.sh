#!/usr/bin/env bash
set -euo pipefail

# Diagnostic CI only: never attach to a household device or source.
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'Use an isolated GitHub Actions runner.' >&2; exit 2; }
package="${1:?Pass the built standalone seek-probe VPKG}"
[[ -f "$package" ]] || { echo 'The seek-probe package is missing.' >&2; exit 2; }
package="$(realpath "$package")"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$HOME/vega/env"
cd "$repo"
app_id=com.dineshdevkota.mediavault.seekprobe
output="$repo/.artifacts/vega-seek-probe"
evidence="$output/runtime"
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
printf '{"sdkPin":"2.0.15159","glAccelerationRequested":false,"standaloneProbe":true,"stockHttpServer":"nginx"}\n' >"$evidence/runtime-mode.json"

appium_pid=''; nginx_pid=''; start_requested=false; virtual_device_verified=false
cleanup() {
  local original_status=$?
  trap - EXIT
  set +e
  if [[ "$virtual_device_verified" == true ]]; then
    timeout --kill-after=2s 15s vega exec vda shell "loggingctl log -v $app_id --since today" 2>&1 |
      tail -c 2097152 >"$evidence/native.log"
  fi
  [[ -z "$appium_pid" ]] || kill "$appium_pid" 2>/dev/null
  [[ -z "$nginx_pid" ]] || kill "$nginx_pid" 2>/dev/null
  if [[ "$start_requested" == true ]]; then
    timeout --kill-after=2s 30s vega virtual-device stop >"$evidence/stop.log" 2>&1
  fi
  exit "$original_status"
}
trap cleanup EXIT

python3 tools/vega/seek-probe/prepare-fixtures.py "$output"
# nginx serves only the two generated controls. Do not record URLs, query
# strings, addresses, headers, or paths. Ranges are sanitized into numeric fields.
python3 - "$output" "$evidence" <<'PY'
from pathlib import Path
import sys
output, evidence = map(Path, sys.argv[1:])
assert all('"' not in str(path) and '\n' not in str(path) for path in (output, evidence))
config = r'''
worker_processes 1;
pid "EVIDENCE/nginx.pid";
error_log "EVIDENCE/nginx-error.log" warn;
events { worker_connections 64; }
http {
  map $uri $fixture { default 0; /Controls.mkv 1; /Controls.mp4 2; }
  map $arg_case $probe_case { default 0; mkv-paused 1; mkv-playing 2; mp4-paused 3; mp4-playing 4; }
  map $request_method $method { default 0; GET 1; HEAD 2; }
  map $http_range $range_start { default -1; "~^bytes=([0-9]+)-[0-9]*$" $1; }
  map $http_range $range_end { default -1; "~^bytes=[0-9]*-([0-9]+)$" $1; }
  map $sent_http_content_range $content_start { default -1; "~^bytes ([0-9]+)-[0-9]+/[0-9]+$" $1; }
  map $sent_http_content_range $content_end { default -1; "~^bytes [0-9]+-([0-9]+)/[0-9]+$" $1; }
  map $sent_http_content_range $content_total { default -1; "~^bytes [0-9]+-[0-9]+/([0-9]+)$" $1; }
  log_format numeric '$msec $fixture $probe_case $method $status $body_bytes_sent $range_start $range_end $content_start $content_end $content_total';
  access_log "EVIDENCE/nginx-access.log" numeric;
  sendfile off;
  server {
    listen 127.0.0.1:8765;
    server_name localhost;
    root "OUTPUT/media";
    location = /Controls.mkv { types { } default_type video/x-matroska; limit_except GET { deny all; } }
    location = /Controls.mp4 { types { } default_type video/mp4; limit_except GET { deny all; } }
    location / { return 404; }
  }
}
'''.replace('EVIDENCE', str(evidence)).replace('OUTPUT', str(output))
(evidence/'nginx.conf').write_text(config)
PY
nginx -v 2>"$evidence/nginx-version.txt"
nginx -p "$evidence/" -c "$evidence/nginx.conf" -t >"$evidence/nginx-config-check.log" 2>&1
nginx -p "$evidence/" -c "$evidence/nginx.conf" -g 'daemon off;' >"$evidence/nginx-console.log" 2>&1 &
nginx_pid=$!
for attempt in {1..30}; do
  kill -0 "$nginx_pid" 2>/dev/null || { echo 'The isolated stock server exited.' >&2; exit 1; }
  if curl --fail --silent --head http://127.0.0.1:8765/Controls.mkv >/dev/null; then break; fi
  sleep 1
done
python3 tools/vega/seek-probe/verify-http.py "$output"

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
vega exec vda reverse tcp:8765 tcp:8765
export PATH="$(dirname "$(vega exec which vda)"):$PATH"
# The driver prints raw RPC bodies outside its logger; keep only warning logs.
appium --address 127.0.0.1 --log-level warn --log "$evidence/appium.log" >/dev/null 2>&1 &
appium_pid=$!
for attempt in {1..60}; do
  if curl --fail --silent http://127.0.0.1:4723/status >/dev/null; then break; fi
  kill -0 "$appium_pid" 2>/dev/null || { echo 'Appium exited before becoming ready.' >&2; exit 1; }
  sleep 1
done
curl --fail --silent http://127.0.0.1:4723/status >/dev/null
timeout --kill-after=2s 60s vega run-app "$package" "$app_id.main" -d VirtualDevice >"$evidence/launch.log" 2>&1
probe_status=0
APPIUM_URL=http://127.0.0.1:4723 PROBE_DEVICE_INFO="$evidence/device.json" PROBE_OUTPUT="$evidence" \
  timeout --kill-after=2s 660s node tools/vega/seek-probe/seek-probe.mjs || probe_status=$?
printf '{"harnessExitCode":%s}\n' "$probe_status" >"$evidence/runner-result.json"
exit "$probe_status"
