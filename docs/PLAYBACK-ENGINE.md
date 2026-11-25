# Apple playback engine

The library/playback feature branch preserves AVPlayer for compatible native
media and server-negotiated Jellyfin playback. Additional direct-file formats
use VideoLAN's VLCKit on both iOS and tvOS. The Android app continues using
Media3/ExoPlayer with device decoders; this does not make every codec available
on every Android device.

## Reproducible dependency

- Official source: https://github.com/videolan/vlckit
- Pinned source revision: `7f98c70f9f0c11fbdf828220890bd6280361ae99`
- Official package manifest: https://github.com/videolan/vlckit/blob/7f98c70f9f0c11fbdf828220890bd6280361ae99/Package.swift
- Binary: https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20261109-1916.zip
- SHA-256: `1fec7232f88e706f44d9a015133e08d742166eb2666cb44915c9f570bf339463`
- This is an official **4.0 prerelease** build. The archive includes multiple
  platforms and is about 910 MB; each app embeds its applicable framework slice.

The binary's checksum was verified against the pinned package manifest. Source
and binary license notices are included in `CineVault/Resources`; the license is
available from the app's About section. VLCKit is LGPL-2.1-or-later. Keep it as a
separate, dynamically linked framework, retain notices and corresponding source
access, and preserve the ability to rebuild the application with a replacement
framework. The upstream README and build scripts describe building VLCKit from
source. The repository's source and XcodeGen configurations describe rebuilding
MediaVault. Never strip these resources from a release package.

## Access boundary

The extra player receives a temporary loopback URL for one authorized file.
MediaVault supplies byte ranges through its existing source reader. The player
does not receive NAS credentials or unrestricted access to other library files.
Profile lock, source changes and playback teardown must revoke that stream.

An additional engine must use the same watched/resume rules, subtitle choices,
next-episode authorization, and device-wide commercial allowances as native
playback. It must not simulate AVPlayer activity to evade or approximate usage
accounting. The private commercial adapter supplies a real engine-neutral
session with its own validation tests.

## Verification and remaining limits

The isolated `FORMATPLAYBACK` fixture supplies H.264/AAC in MKV, MPEG-4/MP3 in
AVI, and VP9/Opus in WebM. Tests must prove advancing playback, seeking and
teardown, not only accept an extension or create a player object. The full
platform checks also cover native playback, sidecars, household controls and
source revocation.

Simulator/emulator tests do not establish HDR/Dolby Vision fidelity, lossless
audio passthrough, maximum bitrate, disc-menu support or performance on physical
hardware. Those are separate device checks; do not advertise them as supported
because a container opened in a simulator. See `dist/AGENT-HANDOFF.md` for the
exact revisions and tests that have completed.
