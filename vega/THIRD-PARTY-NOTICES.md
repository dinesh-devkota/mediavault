# Vega native dependencies

MediaVault's Vega bridge builds the following upstream releases from the exact
archives and SHA-256 values in `native/CMakeLists.txt`. Their original source is
not modified. The build scripts and bridge source are included in this repository.

| Dependency | Release / source | License |
| --- | --- | --- |
| libsmb2 | 6.2, commit `4bc7ea4cdce9cce19e5b271194ae95a6b749b4d3`, [source](https://github.com/sahlberg/libsmb2/tree/4bc7ea4cdce9cce19e5b271194ae95a6b749b4d3) | LGPL 2.1 or later; dynamically linked |
| curl | 8.23.0, [source archive](https://curl.se/download/curl-8.23.0.tar.xz) | curl license |
| Mbed TLS | 3.6.8, [source archive](https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.8/mbedtls-3.6.8.tar.bz2) | Apache 2.0 option of upstream's dual license |
| nlohmann/json | 3.12.0, [source archive](https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz) | MIT |
| utf8proc | 2.12.0, [source archive](https://github.com/JuliaStrings/utf8proc/releases/download/v2.12.0/utf8proc-2.12.0.tar.gz) | MIT; Unicode data license included by upstream |
| Mozilla CA certificates | Bundle dated November 5, 2026, retrieved November 25 from [curl's CA extract](https://curl.se/docs/caextract.html) | Mozilla Public License 2.0 |

Full native license texts are in `licenses/`. JavaScript and Amazon SDK packages
retain their license files in the dependency installation; `package-lock.json`
records the versions and integrity hashes used. Amazon SDK files are not copied
into this repository.

The bundled CA file has SHA-256
`427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285`.
HTTPS verifies both the certificate chain and hostname. Updating the trust bundle
requires reviewing its provenance and changing this recorded hash.

## Rebuilding and relinking

The native build keeps libsmb2 as a separate shared library. The source archive,
complete build instructions, license notices and matching MediaVault bridge
source must accompany any distributed Vega package. Do not replace this with a
static-only SMB build or omit the shared library from packaging. A developer can
build a modified libsmb2 with the same SDK/toolchain and rebuild the app with that
library. Before store distribution, retain the exact source archives with the
release artifacts and verify that the package contains `libMediaVaultNative.so`
and the dynamically loaded libsmb2 library.

The current Vega work is under development and is not an Appstore release.
