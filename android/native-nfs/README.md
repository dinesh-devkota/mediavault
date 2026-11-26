# Android NFS development bridge

The bridge mounts an explicit NFSv3 export, lists regular files and directories,
and reads an exact byte range from an export-relative file. It uses a separate
libnfs shared library. It skips symbolic links and rejects traversal, case
mismatches, and truncated reads. Pathnames are passed as UTF-8 bytes.

With the debug opt-in enabled, Admin can open Sources, connect to an explicit NFS
export, browse to a media folder, and scan it. The same screen handles reconnect,
source edits, and removal. The scoped transport supports exact-case subtitle
matching, photos, and byte-range playback. Replacing the media location creates
a new source that requires its own household grants. Active reads are tied to
the current household session and saved connection. NFSv3 traffic is unencrypted
and intended for private, trusted networks.

## Build and test

Use Android NDK r28c, CMake 3.22 or newer, Python 3.12 and the `patch` command.

```sh
python3 scripts/build_android_nfs.py \
  --ndk "$ANDROID_HOME/ndk/28.2.13676358" \
  --output /tmp/mediavault-nfs-native
```

The build verifies the ABI, ELF page alignment and a separate, unversioned
`libnfs.so` dependency. The output retains the exact source archive, applicable
patch, and scripts for rebuilding it. Build one ABI with `--abi`, or omit it
for all four supported Android ABIs.

Pass `-Pcinevault.nfsDevelopmentLibs=/tmp/mediavault-nfs-native/jniLibs` to
Gradle to include the libraries and instrumented fixtures in a debug build.
Ordinary builds keep the NFS source unavailable. Release builds omit both native
libraries even if the property is supplied.

For a disposable development emulator, start the media export fixture on its host
with `python3 scripts/tests/test_nfs_readonly_probe.py --serve-port 15586 --library-media`.
Run `NfsMediaInstrumentedTest` explicitly with runner arguments
`nfsFixtureHost=10.0.2.2` and `nfsMediaFixturePort=15586`. The bridge-only tests in
`NfsProviderInstrumentedTest` use the default export fixture, without
`--library-media`, and the runner argument `nfsFixturePort`.

A disposable emulator host that can bind TCP port 111 can also start the media
fixture with `--serve-portmapper 111`. The app can then connect normally to host
`10.0.2.2`, export `/media`, and choose `Library`.
Run `NfsSetupNavigationTest` with runner argument `nfsAppFixture=true` only
against this fixture on a fresh disposable Android TV emulator. It exercises
remote input, import, photo decoding, subtitle matching, seeking, and removal.

The native tests exercise real fixture scans, photo reads, case-sensitive
subtitles, seeking, stale stored connections, and household access. Emulator
confirmation of the full setup and playback flow is pending for the app route.

## Distribution

libnfs 5.0.3 is licensed LGPL-2.1-or-later. Its protocol definitions and
generated source carry a simplified BSD license. The build uses the library
target only. Upstream examples and tools are excluded. Preserve the upstream
notices and provide the exact corresponding libnfs source, including the
MediaVault directory-link patch, for any distributed binary.

Before distributing a signed APK with libnfs, satisfy LGPL section 6 through
a user replacement mechanism or an applicable relinking path. The distribution
mechanism remains open.

[libnfs notices](https://github.com/sahlberg/libnfs/blob/libnfs-5.0.3/COPYING) · [LGPL-2.1 section 6](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html)
