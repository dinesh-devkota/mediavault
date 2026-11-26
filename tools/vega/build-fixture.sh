#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$HOME/vega/env"
mkdir -p "$repo/.artifacts"
# Keep native compilation on the host's Linux filesystem, including when the
# repository is mounted from Windows. The release tree stays untouched.
stage="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vega-vvd-fixture.XXXXXX")"
python3 "$repo/tools/vega/stage-fixture.py" "$stage/vega"
cd "$stage/vega"
npm ci
vega project doctor
npm run typecheck
(cd native && vega build -t x86_64 -b Debug --cmakeFlags=-DMEDIAVAULT_VVD_FIXTURE=ON)
npx react-native build-vega --target x86_64 --build-type Debug --max-workers 4 --include-js-bundle true
mapfile -t packages < <(find build/x86_64-debug -maxdepth 1 -type f -name '*.vpkg')
[[ ${#packages[@]} -eq 1 ]] || { echo 'Expected one isolated fixture package.' >&2; exit 1; }
package="${packages[0]}"
vega exec vpt validate "$package"
output="$repo/.artifacts/vega-vvd-fixture-package"
mkdir -p "$output"
bash "$repo/tools/vega/check-package.sh" "$package" fixture x86_64 >"$output/package-validation.json"
vega exec vpt show-contents "$package" >"$output/contents.txt"
grep -Fq 'index.hermes.bundle' "$output/contents.txt"
grep -Fq 'libsmb2.so' "$output/contents.txt"
cp "$package" "$output/MediaVault-SIMULATOR-ONLY-x86_64.vpkg"
printf 'TEST ONLY: temporary synthetic storage. Not for installation on a Fire TV.\nSecure storage and restart persistence require physical hardware validation.\n' >"$output/TEST-ONLY.txt"
sha256sum "$output/MediaVault-SIMULATOR-ONLY-x86_64.vpkg" >"$output/sha256.txt"
