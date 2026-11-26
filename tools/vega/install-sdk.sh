#!/usr/bin/env bash
set -euo pipefail

# Amazon's non-interactive installer; SDK and installer content are pinned.
# Set SKIP_VVD_INSTALL=false only on a supported native Linux/macOS test host.
export NONINTERACTIVE=true
export VEGA_SDK_VERSION=2.0.15159
export SKIP_VVD_INSTALL="${SKIP_VVD_INSTALL:-true}"
installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT
curl --fail --silent --show-error --location \
  https://sdk-installer.vega.labcollab.net/get_vvm.sh --output "$installer"
printf '%s  %s\n' 817e9d4d6fcee9a48abd9cb292eb5844299b41f8759134b8e64dea69a929186c "$installer" | sha256sum --check
bash "$installer"
source "$HOME/vega/env"
vega sdk use "$VEGA_SDK_VERSION"
vega --version
