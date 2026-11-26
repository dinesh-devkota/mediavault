# Apple NFS compile probe

Run on a Mac with Xcode, its tvOS device and simulator SDKs, CMake, and Python 3.12.

```sh
bash scripts/build_apple_nfs_probe.sh
```

The script checks the same libnfs 5.0.3 archive checksum as the Android probe,
applies the existing NFSv3 directory no-follow patch, and runs the existing
read-only fixture tests against a native macOS executable on loopback. It also
links arm64 tvOS 17 deployment-target executables against the device and
simulator SDKs and verifies their Mach-O platform markers. The Apple NFS workflow
runs this command on a hosted Mac when explicitly pushed to
`codex/mediavault-apple-nfs-probe`. GitHub also enables manual dispatch once the
workflow exists in the default branch. Linux can run the native fixture with
`--host-only`. Set `NFS_SOURCE_ARCHIVE` to use a cached copy of the exact source
archive.

The tvOS binaries are compile checks. Testing NFS network behavior on a
tvOS simulator or physical device requires a separate test harness. Store
distribution also requires a reviewed license and packaging path for libnfs
and the local patch. The pilot does not modify any app targets or ship libnfs.

[libnfs 5.0.3 notices](https://github.com/sahlberg/libnfs/blob/libnfs-5.0.3/COPYING) · [LGPL v2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.en.html)
