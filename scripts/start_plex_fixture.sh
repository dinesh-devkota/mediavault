#!/usr/bin/env bash
set -euo pipefail

fixture_dir="${1:?Pass a disposable fixture output directory}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${2:-apple}" in
  apple) advertised_host=127.0.0.1 ;;
  android) advertised_host=10.0.2.2 ;;
  *) echo "Expected apple or android as the fixture platform." >&2; exit 1 ;;
esac
mkdir -p "$fixture_dir"
python3 "$script_dir/plex_fixture.py" "$fixture_dir" --advertised-host "$advertised_host" \
  >"$fixture_dir/server.log" 2>&1 &
fixture_pid=$!
for attempt in {1..30}; do
  if ! kill -0 "$fixture_pid" 2>/dev/null; then break; fi
  if [[ -s "$fixture_dir/fixture.pem" && -s "$fixture_dir/fixture.cer" ]] &&
    curl --noproxy 127.0.0.1 --silent --fail --connect-timeout 1 --max-time 2 \
      --cacert "$fixture_dir/fixture.pem" https://127.0.0.1:18777/health --output /dev/null; then
    echo "$fixture_pid" >"$fixture_dir/server.pid"
    exit 0
  fi
  sleep 1
done

kill "$fixture_pid" 2>/dev/null || true
cat "$fixture_dir/server.log" >&2
echo "Plex fixture did not start." >&2
exit 1
