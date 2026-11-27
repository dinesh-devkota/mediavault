# Google Drive on Apple TV

MediaVault connects an Apple TV to Google Drive through a companion service. The household
Admin opens **Connect Google Drive** in Sources, then opens the displayed link on a phone or
computer. Enter the code from the TV, sign in on Google's website, and use Google Picker to
choose the files. The pairing code expires after ten minutes. Return to the TV to review the
selection and save and scan the source.

Browse your Drive folders in Picker and choose each supported media file and any matching
SRT or WebVTT files you want to use. A source imports up to 100 individually approved files. To match a selected sidecar,
select its video from the same Google Drive folder. Reconnect with the original set of files to
retain the existing source and household grants. Create a separate source for a different
selection. A source added by Admin grants viewers no access until Admin explicitly grants it.

Android uses the system document picker where a Drive provider is available. iPhone uses
Apple Files. Both of those paths work independently of this Apple TV companion.

## Configure Google Cloud

1. In one Google Cloud project, enable the Google Drive API and Google Picker API. Configure
   Google Auth Platform branding and audience. In Data Access, declare only
   `https://www.googleapis.com/auth/drive.file`. This Google scope allows read and write
   operations on files authorized for the app. MediaVault only reads the IDs approved for
   the source. [Drive API scope documentation](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)
2. Create a **Web application** OAuth client in that project. For a companion at
   `https://drive-link.example.com`, register that origin under **Authorized JavaScript
   origins**. Register the exact `https://drive-link.example.com/oauth/callback` under
   **Authorized redirect URIs**, including the callback path with no trailing slash.
   Keep the web client secret in the companion's secret store.
   [Google web OAuth client setup](https://developers.google.com/identity/oauth2/web/guides/get-google-api-clientid)
3. Create a browser API key in the same project. Under **Websites**, allow the companion
   website, for example `https://drive-link.example.com/*`, and `https://docs.google.com/*`
   for the Google Picker iframe. In the key's API restrictions, allow Google Picker API and
   Google Drive API. Copy the numeric Cloud project number from **IAM & Admin → Settings**
   for the Picker app ID. [Google Picker web setup](https://developers.google.com/workspace/drive/picker/guides/web-picker-sample)
4. Add a dedicated account to the test audience for a live pilot. In External Testing,
   Drive authorization and refresh tokens expire after seven days. For a public audience,
   provide the verified domain, app homepage, privacy policy and any other information the
   Google Auth Platform console requests. Google reviews its OAuth configuration separately
   from Apple's App Store review. [Google OAuth audiences](https://support.google.com/cloud/answer/15549945?hl=en)
   · [Google brand verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification)

## Configure the companion service

The service is in `services/drive-companion/` and uses Node.js 24 or newer and its built-in
SQLite module. Run it behind an HTTPS reverse proxy at the configured public origin. Keep the
service listener private and give the service account exclusive access to the database, its
SQLite sidecar files, and backups. The database stores expiring pairing and OAuth state,
selected-file metadata, and encrypted provider credentials. Keep it on persistent storage.

| Environment variable | Value |
| --- | --- |
| `DRIVE_COMPANION_ORIGIN` | Public HTTPS origin, such as `https://drive-link.example.com`. Use the canonical origin without a path, trailing slash, query or fragment. |
| `GOOGLE_CLIENT_ID` | Web OAuth client ID from that project. |
| `GOOGLE_CLIENT_SECRET` | Web OAuth client secret supplied through a secret manager. |
| `GOOGLE_PICKER_API_KEY` | Browser key with the website and API restrictions above. |
| `GOOGLE_APP_ID` | Numeric Cloud project number used by Picker. |
| `DRIVE_COMPANION_DB` | Local filesystem path for the persistent SQLite database. |
| `DRIVE_COMPANION_STORAGE_KEY` | Canonical Base64-encoded 32-byte encryption key for stored credentials. Keep it in a secret manager and available when restoring the database. |
| `HOST` | Optional bind address. The default is `127.0.0.1`. |
| `PORT` | Optional bind port. The default is `8787`. |

Supply these settings through the service environment and run this command from the repository
root.

```sh
npm --prefix services/drive-companion start
```

Forward the public origin's routes to the service, including `/pair` and `/oauth/callback`.
Configure the proxy and monitoring to omit OAuth callback query strings, pairing and
authorization headers, credential-bearing bodies, and media contents from their logs.
The browser holds a short-lived Google access token in memory for Picker.
The companion retains the Google refresh token in its encrypted credential store. The
TV stores its own opaque connection credential in Keychain and sends media requests only
to the configured companion. The Google client secret and Google OAuth tokens stay outside
the TV build.

The companion scopes catalog and range requests to the source's verified file IDs. An
optional Google resource key is forwarded in the Drive resource-keys header for that
particular ID. Drive permissions and MediaVault household grants both apply to media reads.
[Google Drive resource keys](https://developers.google.com/workspace/drive/api/guides/resource-keys)
· [Drive download API](https://developers.google.com/workspace/drive/api/guides/manage-downloads)

## Configure the Apple TV build

Set the public Xcode build setting `MEDIA_VAULT_DRIVE_COMPANION_URL` to the same HTTPS origin.
Xcode puts it in the tvOS app's `MediaVaultDriveCompanionURL` Info.plist key. MediaVault offers
the source when it has a valid companion origin. The endpoint is fixed at build time for
release builds.

This example produces an unsigned tvOS build from the repository root.

```sh
xcodegen generate --spec project.yml
xcodebuild -project CineVault.xcodeproj -scheme CineVault \
  -destination 'generic/platform=tvOS' -configuration Release \
  MEDIA_VAULT_DRIVE_COMPANION_URL=https://drive-link.example.com \
  CODE_SIGNING_ALLOWED=NO build
```

Inspect that the built bundle's Info.plist contains the intended HTTPS origin. The app stores
and uses the connection only for that origin. If the companion moves to another origin,
add it as a new source and grant viewer access again.

## Validate and disconnect

From the repository root, run the companion tests against the synthetic Google fixture.

```sh
npm --prefix services/drive-companion test
```

For local tvOS debug testing, the process environment variable
`MEDIA_VAULT_DRIVE_COMPANION_URL` can point the test app to a trusted HTTPS companion fixture.
Keep the release setting empty for builds that should omit this source. Fixture runs exercise
the companion contract without a live Google account. A live pilot still requires the Google
project, hosted HTTPS companion, and eligible account described above.

Disconnect a source in MediaVault to remove its saved device credential. When the companion
receives the request, it stops active reads and deletes that source's stored credentials and
selected-file records. To revoke the broader Google authorization, remove the app's access
in the user's Google Account. Google revocation can affect all of that user's connections
and clients associated with the same Cloud project.
[Google token revocation](https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke)
