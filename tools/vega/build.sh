#!/usr/bin/env bash
set -euo pipefail

target="${1:-aarch64}"
configuration="${2:-Release}"
app_checks="${3:---verify-app}"
case "$target" in armv7|aarch64|x86_64) ;; *) echo 'Choose armv7, aarch64 or x86_64.' >&2; exit 2;; esac
case "$configuration" in Debug|Release) ;; *) echo 'Choose Debug or Release.' >&2; exit 2;; esac
case "$app_checks" in
  --verify-app) ;;
  --shared-app-checks-by-x86)
    if [[ "$configuration" != Release || "$target" == x86_64 || "${GITHUB_ACTIONS:-}" != true ]]; then
      echo 'Shared checks can be delegated only by the hosted ARM Release matrix jobs.' >&2
      exit 2
    fi
    ;;
  *) echo 'Choose --verify-app or --shared-app-checks-by-x86.' >&2; exit 2 ;;
esac
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$HOME/vega/env"
cd "$repo/vega"
python3 "$repo/tools/vega/stage-fixture.py" --check-production
npm ci
vega project doctor
# These checks read one locked TypeScript tree and have no architecture inputs.
# All matrix jobs still verify their SDK and native/JS package contents.
if [[ "$app_checks" == --verify-app ]]; then
  npm run typecheck
  npm run lint
  npm run test:domain
fi

# Build the separate native package before the application's autolink step.
(cd native && vega build -t "$target" -b "$configuration" --cmakeFlags=-DMEDIAVAULT_VVD_FIXTURE=OFF)
# The React Native command bundles Hermes before calling the native packager.
# Calling `vega build` directly here can produce a VPKG without its interface.
npx react-native build-vega --target "$target" --build-type "$configuration" --max-workers 4 --include-js-bundle true

# The SDK keeps a second staging copy under build/private. Publish only its
# final architecture/configuration output, or artifact consumers see duplicates.
mapfile -t packages < <(find "build/${target}-${configuration,,}" -maxdepth 1 -type f -name '*.vpkg')
if [[ ${#packages[@]} -ne 1 ]]; then
  printf 'Expected one %s package; found %s.\n' "$target" "${#packages[@]}" >&2
  exit 1
fi
package="${packages[0]}"
vega exec vpt validate "$package"
mkdir -p build/evidence
bash "$repo/tools/vega/check-package.sh" "$package" production "$target" >"build/evidence/${target}-production-storage.json"
vega exec vpt show-contents "$package" | tee "build/evidence/${target}-contents.txt"
grep -Fq 'libMediaVaultNative.so' "build/evidence/${target}-contents.txt"
grep -Eq 'libsmb2\.so(\.|[[:space:]]|$)' "build/evidence/${target}-contents.txt"
grep -Fq 'index.hermes.bundle' "build/evidence/${target}-contents.txt"
sha256sum "$package" > "build/evidence/${target}-sha256.txt"
