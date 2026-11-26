#!/usr/bin/env bash
set -euo pipefail
package="${1:?Pass a VPKG}"
mode="${2:?Choose production or fixture}"
target="${3:?Pass its architecture}"
case "$mode" in production|fixture) ;; *) exit 2;; esac
case "$target" in armv7|aarch64|x86_64) ;; *) exit 2;; esac
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -f "$scratch/manifest.toml" "$scratch/native.so"; rmdir "$scratch"' EXIT
vega exec vpt dump "$package" manifest.toml --dest-path "$scratch/manifest.toml" >/dev/null
vega exec vpt dump "$package" "lib/$target/libMediaVaultNative.so" --dest-path "$scratch/native.so" >/dev/null
python3 "$script_dir/check-package.py" "$mode" "$target" "$scratch/manifest.toml" "$scratch/native.so"
