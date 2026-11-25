# Android NFS development bridge

The bridge mounts an explicit NFSv3 export, lists regular files and directories,
and reads an exact byte range from an export-relative file. It uses a separate
libnfs shared library. It skips symbolic links and rejects traversal, case
mismatches, and truncated reads. Pathnames are passed as UTF-8 bytes.

NFS setup, catalog, household authorization, and playback still need app wiring through the
normal source operations before release. NFSv3 traffic is unencrypted and intended for private,
trusted networks.

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
Gradle to include the libraries and the instrumented fixture tests in a debug
build. Library packaging is confined to this debug configuration. The hosted
NFS job provides the synthetic fixture on the Android TV emulator host loopback.

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
