# MediaVault Google Drive on Apple TV handoff

## Resume the work

This branch contains the Google Drive for Apple TV implementation and this handoff. The
feature is open as a draft. The tested source revision is
`45eaf54ac8bfb02f9981b63af1deb94c8110db84`. Its base is
`dinesh-devkota-sonepar-build-cinevault-tvos-app` at
`1c1635701cae9ee3886f48eed89141296b25c420`.
[Draft pull request #33](https://github.com/dinesh-devkota/mediavault/pull/33)

Clone the handoff branch from any machine with Git.

```sh
git clone --branch codex/mediavault-google-drive-tvos-handoff https://github.com/dinesh-devkota/mediavault.git
cd mediavault
```

In an existing clone, use this command to check out the handoff at the fetched revision.
Use `git switch -c <new-branch-name>` if you plan to make changes from it.

```sh
git fetch origin codex/mediavault-google-drive-tvos-handoff
git switch --detach FETCH_HEAD
```

Use the feature branch `codex/mediavault-google-drive-tvos` for changes intended for PR #33.
Use the handoff branch to retrieve this document together with the exact tested source.

## What is implemented

- A household Admin scans a QR code or opens the pairing page on a phone or computer.
  Google Picker lets them navigate Drive folders and select up to 100 individual files.
- The Apple TV reviews and saves the selection, imports supported video and photos, and
  matches selected SRT or WebVTT files from the same Drive folder. Reconnect uses the same
  selection to keep existing MediaVault records and household grants.
- The HTTPS companion stores encrypted Google refresh credentials in SQLite. The TV stores
  a source-specific companion credential in Keychain. Playback reads selected files through
  validated byte ranges. Viewers need an explicit grant from the Admin.
- Removing a source invalidates its local access. When the companion receives the disconnect,
  it removes the grant and stops active reads. An unsaved pairing draft expires automatically.

The companion is under [services/drive-companion](../services/drive-companion). Apple app code
starts in [DriveCompanionSourceEditor.swift](../CineVault/Views/DriveCompanionSourceEditor.swift),
[DriveCompanionClient.swift](../CineVault/Services/DriveCompanionClient.swift), and
[DriveCompanionFileSource.swift](../CineVault/Services/DriveCompanionFileSource.swift).

## Verification

| Check on the source revision above | Result |
| --- | --- |
| Companion with simulated Google OAuth, Picker, and Drive | [13 passed](https://github.com/dinesh-devkota/mediavault/actions/runs/45928489248) |
| Unsigned Apple TV build and Swift core tests | [Passed](https://github.com/dinesh-devkota/mediavault/actions/runs/45928489321) |
| Apple TV simulator | [282 passed with zero failures or skips](https://github.com/dinesh-devkota/mediavault/actions/runs/45928489445), including remote pairing, reconnect, and an AVPlayer seek to eight seconds |
| Android TV build and emulator | [Passed after rerunning the Maven Central rate-limit failure](https://github.com/dinesh-devkota/mediavault/actions/runs/45928489281). All 129 emulator tests passed with zero failures or skips |
| iPhone simulator and unsigned release | [277 passed with zero failures or skips](https://github.com/dinesh-devkota/mediavault/actions/runs/45928489292). The unsigned release build and privacy resource check passed |

The two loopback HTTPS fixture tests, seven XCTest report utility tests, workflow lint,
and Git whitespace checks also passed. This handoff branch adds only Markdown to the
tested source.

Rerun the local synthetic companion and fixture suites from the repository root.

```sh
npm --prefix services/drive-companion test
python3 -m unittest discover -s scripts/tests -p test_drive_companion_fixture.py
python3 -m unittest discover -s scripts/tests -p test_xcresult_report.py
```

The `NAS integration` GitHub workflow sets up temporary synthetic services and runs the full
Apple TV simulator suite. It requires the pairing, reconnect scan, and seek tests to pass.
[Apple TV simulator workflow](../.github/workflows/nas-integration.yml)

## What remains for a live pilot

1. Use a Google Cloud project with the Google Drive and Google Picker APIs enabled.
   Configure the consent screen, register a web OAuth client, restrict the Picker browser API
   key, and add an eligible Google test account. Register the companion HTTPS origin and the
   exact `/oauth/callback` URL with the OAuth client.
2. Deploy the Node.js 24 companion behind HTTPS with a persistent private SQLite volume.
   Supply the OAuth client secret and database encryption key through a secret manager.
3. Configure `MEDIA_VAULT_DRIVE_COMPANION_URL` in an Apple TV build. The connection entry is
   available when this setting contains the companion's valid HTTPS origin.
4. Verify a live sign-in, file selection, photo viewing, sidecar subtitles, playback and
   seeking, reconnect, viewer restrictions, and disconnect using dedicated test media.
   A physical Apple TV run requires an appropriately signed build.

Google Cloud registration, hosting, live provider verification, and Apple submission are
pending. No store or TestFlight release was published. Keep real secrets out of the
repository and use synthetic fixtures for CI.
[Companion configuration and operator guide](GOOGLE-DRIVE-COMPANION.md)
