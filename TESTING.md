# CamDesk Tests

The suite uses FFmpeg-generated video and services bound to `127.0.0.1`. It does not connect to physical cameras or use camera credentials.

## Run everything

Requirements: macOS 14+, Swift 5.9+, Python 3, FFmpeg and ffprobe on `PATH`.

```sh
./Tests/run-tests.sh
```

The script creates fixtures and recordings in a temporary directory, starts the loopback services, runs the tests, and removes the temporary directory on exit.

`ModelTests` creates a Keychain item under a random test identifier and deletes it when the test ends. macOS may ask you to allow the test executable to access Keychain.

## Coverage

- JPEG frame boundary parsing and size limits
- RTSP TCP/UDP, MJPEG and HLS decoding with generated local streams
- Recording finalization, single-session handoff, cancellation, nonzero exit handling and local playback
- Demo preview process reuse and application-exit recording flush
- FFmpeg version validation, incorrect executables and probe timeouts
- Native video zoom, panning, wheel input and reset
- Recording completion feedback, library refresh and engine changes using an isolated configuration
- ONVIF WS-Security, media profiles, stream URI and PTZ SOAP calls
- Invalid ONVIF credentials
- Configuration serialization and Keychain add/read/update/delete

The tests do not certify compatibility with every camera model. Hardware PTZ movement and long-running recording need to be checked with the device in question.
