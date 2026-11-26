#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$source_dir/../../.." && pwd)"
source "$HOME/vega/env"
dependencies="$(realpath "${PROBE_NODE_MODULES:-$repo/vega/node_modules}")"
[[ -d "$dependencies/react-native" ]] || { echo 'Run npm ci in vega first.' >&2; exit 2; }
output="$repo/.artifacts/vega-render-probe"
mkdir -p "$output"
stage="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vega-render-probe.XXXXXX")"
cp "$source_dir"/{app.json,manifest.toml,index.js,metro.config.js,babel.config.js,tsconfig.json,package.json} "$stage/"
cp -R "$source_dir/src" "$stage/src"
# Keep the SDK template Metro config intact. Only make the external, pinned
# dependency directory visible to Metro's symlink-aware file watcher.
mv "$stage/metro.config.js" "$stage/metro.template.config.js"
python3 - "$stage" "$dependencies" "$repo" "$source_dir" "$output" <<'PY'
import hashlib, json, pathlib, sys
stage, dependencies, repo, source, output = map(pathlib.Path, sys.argv[1:])
lock = json.loads((repo / 'vega/package-lock.json').read_text())
package = json.loads((source / 'package.json').read_text())
provenance = json.loads((source / 'provenance.json').read_text())
for name, digest in provenance['unchangedTemplateFilesSha256'].items():
    assert hashlib.sha256((source/name).read_bytes()).hexdigest() == digest, name
installed_versions = {}
excluded_native = []
view = stage/'node_modules'
view.mkdir()
for entry in dependencies.iterdir():
    if entry.name == '.package-lock.json':
        continue
    entries = list(entry.iterdir()) if entry.name.startswith('@') and entry.is_dir() else [entry]
    for package_path in entries:
        metadata = package_path/'package.json'
        details = json.loads(metadata.read_text()) if metadata.is_file() else {}
        if details.get('kepler', {}).get('projectType') == 'turbomodule':
            assert details.get('name') not in package['dependencies'], details.get('name')
            assert details.get('name') in {'@mediavault/native', '@amazon-devices/react-native-w3cmedia', '@amazon-devices/kepler-media-controls', '@amazon-devices/keplermediadescriptor'}, details.get('name')
            excluded_native.append({'name': details['name'], 'type': 'turbomodule', 'version': details.get('version')})
            continue
        target = view/package_path.relative_to(dependencies)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(package_path, target_is_directory=package_path.is_dir())
for name, version in {**package['dependencies'], **package['devDependencies']}.items():
    resolved = lock['packages']['node_modules/' + name]['version']
    if version != resolved:
        assert name == '@amazon-devices/react-native-kepler' and version == lock['packages']['']['dependencies'][name], name
    installed = json.loads((dependencies/name/'package.json').read_text())['version']
    # Kepler adds the React Native ABI as semver build metadata after installation.
    assert installed.split('+', 1)[0] == resolved, name
    installed_versions[name] = installed
(stage/'metro.config.js').write_text("const config = require('./metro.template.config');\nmodule.exports = {...config, watchFolders: [...(config.watchFolders || []), " + json.dumps(str(dependencies)) + "]};\n")
provenance.update(applicationLockSha256=hashlib.sha256((repo/'vega/package-lock.json').read_bytes()).hexdigest(),
                  externalDependencyWatchFolderOnly=True, dependencyInstall=str(dependencies), installedVersions=installed_versions, excludedUnrequestedNativePackages=excluded_native)
(output/'build-provenance.json').write_text(json.dumps(provenance, indent=2)+'\n')
PY
cd "$stage"
vega project doctor
npm run typecheck
npm run build:debug
mapfile -t packages < <(find build/x86_64-debug -maxdepth 1 -type f -name '*.vpkg')
[[ ${#packages[@]} -eq 1 ]] || { echo 'Expected one isolated Debug x86_64 probe package.' >&2; exit 1; }
vega exec vpt validate "${packages[0]}"
vega exec vpt show-contents "${packages[0]}" >"$output/package-contents.txt"
vega exec vpt dump "${packages[0]}" manifest.toml --dest-path "$output/packaged-manifest.toml" >/dev/null
python3 - "$output" <<'PY'
import pathlib, re, sys
output = pathlib.Path(sys.argv[1])
# vpt already validates TOML; check the generated package section without extra Python dependencies.
manifest = (output/'packaged-manifest.toml').read_text()
package = re.search(r'(?ms)^\[package\]\s*(.*?)(?=^\[|\Z)', manifest)
assert package and re.search(r'^id\s*=\s*"com\.dineshdevkota\.mediavault\.renderprobe"\s*$', package.group(1), re.M)
contents = (output/'package-contents.txt').read_text()
assert 'index.hermes.bundle' in contents and '.png' in contents
assert 'libMediaVaultNative' not in contents and 'libsmb2' not in contents
PY
cp "${packages[0]}" "$output/MediaVault-RENDER-PROBE-x86_64.vpkg"
sha256sum "$output/MediaVault-RENDER-PROBE-x86_64.vpkg" >"$output/package.sha256.txt"
printf 'Isolated render probe built; staging retained at %s. No device was contacted.\n' "$stage"
