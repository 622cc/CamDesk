# CamDesk

[简体中文](#简体中文) · [English](#english)

## 简体中文

CamDesk 是一款原生 macOS IP 摄像头查看与本地录像工具。它支持 RTSP 视频、ONVIF 云台、截图和 MKV 录像，摄像头配置保存在本机。

- 单画面和多画面观看
- ONVIF 设备发现、云台和预置位
- 截图、原码录像及本地回放
- 视频缩放、音频监听和系统浅色/深色外观
- 窄窗口下视频优先占满空间，检查器可从工具栏弹出

## English

CamDesk is a native macOS IP camera viewer and local recorder. It supports RTSP video, ONVIF PTZ, snapshots, and MKV recording. Camera settings stay on your Mac.

- Single-camera and multi-camera viewing
- ONVIF discovery, PTZ, and presets
- Snapshots, stream-copy recording, and local playback
- Digital zoom, audio monitoring, and system appearance
- At narrow widths, the inspector gets out of the way and remains available from the toolbar

## Requirements

- macOS 14 or later
- Apple Silicon Mac for the included build script
- Swift 5.9 or later and the macOS Command Line Tools
- FFmpeg 9 or a compatible build for live video, audio and recording

CamDesk does not bundle FFmpeg. Set its path in Settings if it is installed elsewhere. The app uses Bundle ID `com.github.622cc.camdesk`.

Existing CamDesk installations using Bundle ID `local.camdesk.mac` are migrated on first launch: the configuration file is copied, never moved; Keychain entries are copied to the new service name when a camera is opened. The old configuration and Keychain entries remain available for rollback.

## Build

```sh
./build.sh
open build/CamDesk.app
```

`build.sh` also writes `dist/CamDesk-<version>-arm64.dmg` and its `.sha256` checksum. Open the disk image and drag CamDesk to Applications.

To build the executable with Swift Package Manager:

```sh
swift build
```

Builds are ad-hoc signed and not notarized, because notarization needs an Apple Developer ID. A downloaded copy is therefore quarantined by Gatekeeper. To open it once: right-click CamDesk in Applications and choose Open, or run `xattr -d com.apple.quarantine /Applications/CamDesk.app`. Builders with a Developer ID can pass it in: `CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh`.

Camera use needs FFmpeg installed on the Mac that runs CamDesk; the disk image does not include it.

## Add a camera

Add an RTSP or HTTP stream URL. Enter camera credentials in the separate username and password fields; CamDesk stores them in Keychain. For ONVIF, add the device service URL and choose **Read profiles**. Local discovery finds ONVIF devices that respond to WS-Discovery on the same network.

RTSP and ONVIF credentials are passed to the FFmpeg process when a connection is opened. This is a hard limitation of FFmpeg: its RTSP demuxer has no `-user`/`-password` options, so the URL is the only place a credential can go, and the URL is a process argument. CamDesk cannot hide it without patching FFmpeg.

Practical consequences, stated plainly:

- Any process running as **the same macOS user** can read the argument with `ps` while a camera is connected.
- Other users on the machine, and anything outside that login session, cannot.

Mitigations that do work: use a camera account with narrower privileges than the admin account, keep sensitive cameras on a separate login, and stop the stream when finished. Do not run untrusted software in the same login session as CamDesk.

## Tests

```sh
./Tests/run-tests.sh
```

The integration tests start synthetic RTSP, MJPEG, HLS and ONVIF services on loopback only. They use generated color bars and fake credentials; they do not read camera accounts or connect to physical devices. Tests write temporary media under the system temporary directory. The Keychain test creates and removes an item with a random identifier.

For the ONVIF and video protocol coverage and current hardware test status, see [TESTING.md](TESTING.md).

## Working on CamDesk

Read [AGENTS.md](AGENTS.md) first. Every change must do all three of these before it counts as done:

1. **Install over the local copy.** Build, then replace `/Applications/CamDesk.app` and confirm the version and binary hash match the new build.
2. **Update the handover.** Append an entry to the change log in [HANDOVER.md](HANDOVER.md) with what changed, why, how it was verified, and how to roll back.
3. **Push to GitHub.** Commit and push to `origin/main`, and upload the disk image when the version changes.

[HANDOVER.md](HANDOVER.md) is the current-state snapshot: install path, release artifacts, architecture decisions, and known limits.

## Limits

CamDesk is a local viewer and recorder. It has no cloud relay, cloud recording, iCloud sync, HomeKit integration, motion alerts, push notifications or two-way talk. PTZ controls require an ONVIF camera that exposes a PTZ service. Camera firmware and stream settings vary, so test with the model you use.

## License

MIT. See [LICENSE](LICENSE).
