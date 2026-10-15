# CamDesk

CamDesk is a native macOS viewer for IP cameras. It supports RTSP preview, ONVIF pan/tilt controls, snapshots and local recording.

Pick a camera from the sidebar to view it. Use the inspector for digital zoom and camera controls. Recordings use MKV and keep the camera's original video stream. On cameras that only allow one RTSP client, recording temporarily takes over that connection and the live preview resumes when recording stops; audio monitoring pauses during that time.

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

To build the executable with Swift Package Manager:

```sh
swift build
```

`build.sh` creates a local ad-hoc-signed app. It is not notarized.

## Add a camera

Add an RTSP or HTTP stream URL. Enter camera credentials in the separate username and password fields; CamDesk stores them in Keychain. For ONVIF, add the device service URL and choose **Read profiles**. Local discovery finds ONVIF devices that respond to WS-Discovery on the same network.

RTSP and ONVIF credentials are passed to the FFmpeg process when a connection is opened. Other processes running as the same macOS user may be able to inspect process arguments while connected. Use a dedicated camera account and avoid running untrusted software in the same login session.

## Tests

```sh
./Tests/run-tests.sh
```

The integration tests start synthetic RTSP, MJPEG, HLS and ONVIF services on loopback only. They use generated color bars and fake credentials; they do not read camera accounts or connect to physical devices. Tests write temporary media under the system temporary directory. The Keychain test creates and removes an item with a random identifier.

For the ONVIF and video protocol coverage and current hardware test status, see [TESTING.md](TESTING.md).

## Limits

CamDesk is a local viewer and recorder. It has no cloud relay, cloud recording, iCloud sync, HomeKit integration, motion alerts, push notifications or two-way talk. PTZ controls require an ONVIF camera that exposes a PTZ service. Camera firmware and stream settings vary, so test with the model you use.

## License

MIT. See [LICENSE](LICENSE).
