# Additional media sources

The current development candidate includes SMB, HTTPS WebDAV, Jellyfin, Plex,
personal OneDrive, and Dropbox source adapters. Dropbox setup is available on
Apple TV and Android. Its iPhone setup is tracked in a separate draft. Test coverage
and remaining limits are recorded in [TESTING.md](TESTING.md) and the
[handoff](../dist/AGENT-HANDOFF.md); a merged connector does not establish live-account
or physical-device compatibility. See the [user guide](MEDIA-GUIDE.md) for setup.

The estimates below preserve the original planning assessment. They are engineering
effort, not delivery dates or a current list of missing connectors. They include
browsing, playback, seeking, reconnects, errors and tests, but exclude provider review delays.

## Foundation

Allow **5–10 engineer-days** to separate source access from SMB. Current scanners,
players, photo readers and subtitle loaders call SMB directly. A shared provider
interface needs stable source/item identities, capabilities, folder listing, reads
or playable URLs, secure credentials, cancellation and reconnection. SMB becomes
the first adapter and must retain its existing behavior.

File sources should continue using the scanner. Media servers should import their
catalog and metadata instead of crawling their files. Household access rules must
apply at browsing, search, image loading, playback and next-episode selection, using
provider identities. New connections must not become available to viewer profiles
without Admin granting access.

## Relative effort and user setup

These estimates are additional to the foundation above.

| Source | Estimated engineering effort | What the user sets up |
|---|---:|---|
| WebDAV | 5–10 days | Enable WebDAV on the NAS/server; enter an HTTPS address and credentials. |
| Jellyfin | 10–20 days | Run Jellyfin on a NAS/PC, configure its media libraries, then use the server address and login or Quick Connect. |
| Emby | 5–10 additional days after Jellyfin | Run Emby and connect a server user; it still needs a separate connector. |
| Plex | 15–25 days | Run Plex Media Server, link a Plex account and choose an accessible server. |
| NFS | 10–15 days | Enable NAS exports and authorize the TV/device address; some setups need UID/GID mapping. |
| First cloud provider | 15–25 days, plus any review | Sign in, authorize access and choose media folders. |
| Each additional cloud provider | 5–15 days | Provider-specific authorization and download handling. |

Connecting an already configured server should take minutes. Installing a server,
configuring its permissions and completing its first library scan are separate work.

**Recommended order:** foundation → WebDAV → Jellyfin → Emby → Plex, then NFS or
one requested cloud provider. Put Jellyfin first if server metadata and transcoding
matter more than the quickest additional NAS connection. The full source matrix
is a multi-month project.

## Technical considerations

- **WebDAV** uses `PROPFIND` for enumeration and HTTP reads for files. Handle path
  escaping, authentication, varied server responses and byte-range seeking.
  [WebDAV standard](https://www.rfc-editor.org/info/rfc4918/)
- **Jellyfin** has TV-friendly Quick Connect and playback negotiation for direct
  play, remuxing and transcoding. A capable server could supply an Apple-compatible
  stream; adding a connection alone does not add MKV decoding to the app.
  [Quick Connect](https://jellyfin.org/docs/general/server/quick-connect/),
  [transcoding](https://jellyfin.org/docs/general/post-install/transcoding/)
- **Emby** uses its own user tokens, media sources and playback-session API. Its
  similarities to Jellyfin help architecture, but do not eliminate a separate adapter.
  [Authentication](https://dev.emby.media/doc/restapi/User-Authentication.html),
  [playback](https://dev.emby.media/doc/restapi/Playback-Guidelines.html)
- **Plex** requires account linking, accessible-server discovery and playback-session
  handling. Remote video can depend on Plex subscriptions; do not promise that all
  remote playback is free.
  [Plex API](https://developer.plex.tv/pms/),
  [remote requirements](https://support.plex.tv/articles/requirements-for-remote-playback-of-personal-media/)
- **NFS** needs native packaging and bridging on both platforms. A library such as
  libnfs also needs distribution-license review; its core is LGPL-2.1-or-later.
  [libnfs license](https://raw.githubusercontent.com/sahlberg/libnfs/master/COPYING),
  [NAS NFS permissions](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/file_share_privilege_nfs)
- **Cloud providers** each need their own adapter. Device-code login can make
  OneDrive TV setup straightforward, while temporary download URLs need careful
  refresh/range handling. Dropbox supports installed-app authorization with PKCE.
  Broad Google Drive read access uses restricted scopes and may require additional
  verification or assessment, depending on data handling.
  [Microsoft device login](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code),
  [OneDrive downloads](https://learn.microsoft.com/en-us/graph/api/driveitem-get-content?view=graph-rest-1.0),
  [Dropbox OAuth](https://docs.dropboxapi.com/dropbox-api/docs/oauth),
  [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)

Assessment reviewed on **2026-11-24**. [Infuse connections](https://firecore.com/infuse)
provided the original comparison point; use the current status above for implemented sources.

## Registration and Apple TV sign-in research

- **OneDrive.** Register a Microsoft Entra public client for the intended
  account types. The device-code flow needs the public application ID. Use
  delegated `Files.Read` and request `offline_access` for refresh. Choose the
  appropriate authority for personal accounts, organizational accounts, or both.
  [Microsoft device-code flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
  [Graph permissions](https://learn.microsoft.com/en-us/graph/permissions-reference#filesread)
- **Dropbox.** Register a scoped Dropbox API app with Full Dropbox access to
  choose folders already in the account. Enable `files.metadata.read` and
  `files.content.read`. Enter its public app key in the MediaVault source setup.
  Approve in a Dropbox browser session and enter the one-time code shown there.
  Dropbox supports PKCE with offline access and a manual code when the request
  omits a redirect URI. A production app can provide its own registered public
  key. Check the Dropbox App Console for linked-account limits and production
  access requirements. [Dropbox OAuth](https://developers.dropbox.com/oauth-guide)
- **Google Drive.** Enable the Drive API in a Google Cloud project and register
  OAuth clients for the chosen authorization flow. The listed TV device flow
  supports `drive.file` and `drive.appdata`. Broad access to existing files needs
  a different approved flow, and `drive.readonly` is restricted. Design per-file
  authorization or an approved companion flow for the intended library access.
  Keep any required confidential client secret outside the TV binary.
  [Google limited-input OAuth](https://developers.google.com/identity/protocols/oauth2/limited-input-device)
  [Drive scope classifications](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)
