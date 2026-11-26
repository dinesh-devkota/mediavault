# Native host checks

These Linux tests compile the production path, relay and key-creation policy code. The optional integration cases also compile production SMB and HTTP transports with the same pinned libsmb2, curl and MbedTLS versions as the Vega module.

Basic host suite (CMake 3.25 or newer also exercises the production configuration guards):

```sh
cmake -S vega/native/tests -B .artifacts/native-host-tests -G Ninja
cmake --build .artifacts/native-host-tests --parallel 3
ctest --test-dir .artifacts/native-host-tests --output-on-failure
```

For real SMB and HTTPS integration, install `openssl`, `ffmpeg`, and the Python packages in `scripts/nas-test-requirements.txt`, then run:

```sh
cmake -S vega/native/tests -B .artifacts/native-host-tests -G Ninja -DMEDIAVAULT_NATIVE_INTEGRATION=ON
cmake --build .artifacts/native-host-tests --target mediavault_native_tests --parallel 3
python3 vega/native/tests/integration_fixture.py run "$PWD/.artifacts/native-host-tests"
```

The runner starts the repository's synthetic NAS on loopback port 1445 and temporary HTTPS servers on loopback ephemeral ports. It adds Unicode and binary fixtures only inside the build directory, runs all cases sequentially, and shuts down services even on failure. The test executable trusts a generated fixture CA through its own generated `TrustRoots.h`; the shipping module's trust bundle and TLS verification remain unchanged. Do not run these integration cases through standalone `ctest` without the runner's services and environment.

Evidence is written to `integration-results.xml`, `fixture/nas.log`, and `fixture/http-audit.jsonl` under the build directory. The audit records whether authentication headers were present, never their values. Retain those files for CI evidence; do not upload generated `*.key` files.

Coverage includes real SMB authentication, folder listing, stat, ranges, Unicode names; real HTTPS trust and hostname validation, authentication, redirects without credential forwarding, request/response limits, range headers and bytes, and profile cancellation. The transport tests do not emulate the device keystore, decoder, application permissions, or Fire TV hardware. Those require platform/device checks.

Separate fixture executables verify the disposable simulator target's exact synthetic NAS allowlist, memory-only records, cancellation rollback, capacity limits, and OS randomness bounds. Production CMake is invoked to verify rejection of Release, RelWithDebInfo, device architectures, and the shipping package identity. The optional transport fixture target compiles the real SMB and HTTP entry points with the simulator restriction enabled; it reads the loopback NAS and confirms that even trusted fixture HTTPS requests are blocked before transmission. These checks do not establish device-keystore persistence or security.
