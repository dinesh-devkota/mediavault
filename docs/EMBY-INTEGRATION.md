# Emby integration

On Android TV or Apple TV, open Sources as Admin, choose Emby, and enter the complete HTTPS address of a server you can already reach from the device. Use the Emby user account that has access to the movies or shows you want. MediaVault saves one selected library per source. Use Edit to rename or reconnect a source. Reconnect with the same account and library to keep existing MediaVault history.

Keep Emby server sign-in separate from MediaVault household profiles. New libraries start hidden from viewers. An Admin can explicitly grant a profile access to the library in household settings. The profile’s movie and show rating limits, Watchlist and playback history continue to apply. The source account sends playback progress to Emby for the MediaVault Admin session only.

The integration plays compatible direct streams and seeks over authenticated byte ranges. It supports native embedded tracks and can read external text subtitles from the negotiated Emby media source. Existing SMB sidecars and SubDL search are also available for their supported sources and matched titles. Apple TV displays primary Emby artwork for movie and show cards. Photos and server-side transcoding are still open.

The clients use the public Emby REST API and platform networking and playback libraries. MediaVault does not bundle the Emby server, Emby SDK or Emby assets. The optional local test downloads the official server image and discards its synthetic media and credentials at the end of the run. [Emby REST API](https://dev.emby.media/doc/restapi/) [Subtitle endpoint](https://dev.emby.media/doc/restapi/Subtitles.html) [Image service](https://dev.emby.media/reference/RestAPI/ImageService.html)

## Verification

- On a Linux cloud checkout with Docker, ffmpeg and the Android build tools, run `python3 scripts/test_emby_fixture.py`. It creates a fresh account, movie and English SRT using the pinned official Emby image and exercises sign-in, library discovery, import paging, range reads, subtitle retrieval, playback progress and sign-out.
- The Android TV runtime job exercises the HTTPS setup form, Room import, Keystore restoration, revoking a household grant, and seeking to a rendered video frame.
- The Apple TV simulator job exercises catalog grouping and case-sensitive IDs, library grants, credential-scoped request fixtures, range playback authorization, subtitle retrieval, and remote navigation to the setup form. The unsigned tvOS CI job verifies the production build independently.
- Signed distribution and physical Apple TV verification require separate access. App Store approval is determined by Apple after review of a submitted build.
