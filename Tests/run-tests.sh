#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
FFMPEG_PATH="${FFMPEG_PATH:-$(command -v ffmpeg || true)}"
FFPROBE_PATH="${FFPROBE_PATH:-$(command -v ffprobe || true)}"
if [[ -z "$FFMPEG_PATH" || -z "$FFPROBE_PATH" ]]; then
  echo "Install FFmpeg and make ffmpeg/ffprobe available on PATH." >&2
  exit 1
fi
SDK="$(/usr/bin/xcrun --show-sdk-path)"
TARGET=arm64-apple-macosx14.0
COMMON=(Sources/Compatibility.swift Sources/FFmpegLocator.swift Sources/Models.swift Sources/MediaEngine.swift Sources/ONVIF.swift Sources/VideoZoom.swift)
TMP="$(mktemp -d "${TMPDIR:-/tmp}/camdesk-tests.XXXXXX")"
export FFPROBE_PATH CAMDESK_TEST_OUTPUT="$TMP/output" CAMDESK_FIXTURE_ROOT="$TMP/fixtures"
mkdir -p "$CAMDESK_TEST_OUTPUT" "$CAMDESK_FIXTURE_ROOT"
HTTP_PID=""; AUTH_PID=""; HLS_PID=""
cleanup() {
  for pid in "$HTTP_PID" "$AUTH_PID" "$HLS_PID"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  case "$TMP" in
    "${TMPDIR:-/tmp}"/camdesk-tests.*) rm -rf "$TMP" ;;
    *) echo "Refusing to remove unexpected test path: $TMP" >&2 ;;
  esac
}
trap cleanup EXIT
compile_run() {
  local name="$1"; shift
  echo "== $name =="
  /usr/bin/xcrun swiftc -swift-version 5 -target "$TARGET" -sdk "$SDK" "$@" -o "$TMP/$name"
  "$TMP/$name"
}
compile_run FFmpegGateTests Sources/FFmpegLocator.swift Tests/FFmpegGateTests.swift
compile_run ReleaseNotesTests Sources/ReleaseNotesView.swift Tests/ReleaseNotesTests.swift
compile_run MediaEngineTests Sources/FFmpegLocator.swift Sources/MediaEngine.swift Tests/MediaEngineTests.swift
compile_run VideoZoomTests "${COMMON[@]}" Tests/VideoZoomTests.swift
compile_run ONVIFTests Sources/ONVIF.swift Tests/ONVIFTests.swift
compile_run ModelTests "${COMMON[@]}" Tests/ModelTests.swift
compile_run StoreBehaviorTests "${COMMON[@]}" Tests/StoreBehaviorTests.swift

"$FFMPEG_PATH" -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=12 \
  -t 3 -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
  -x264-params aud=1:repeat-headers=1:keyint=12 -f h264 -n "$CAMDESK_FIXTURE_ROOT/fixture.h264"
"$FFMPEG_PATH" -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=1 \
  -frames:v 1 -n "$CAMDESK_FIXTURE_ROOT/snapshot.jpg"
python3 Tests/fixture_server.py >"$TMP/http-fixture.log" 2>&1 & HTTP_PID=$!
python3 Tests/onvif_fixture_auth.py >"$TMP/onvif-fixture.log" 2>&1 & AUTH_PID=$!
"$FFMPEG_PATH" -hide_banner -loglevel error -re -f lavfi -i testsrc2=size=640x360:rate=12 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -c:v libx264 -preset ultrafast \
  -tune zerolatency -g 12 -c:a aac -f hls -hls_time 1 -hls_list_size 6 \
  -hls_flags delete_segments -hls_segment_filename "$CAMDESK_FIXTURE_ROOT/hls-%05d.ts" \
  -n "$CAMDESK_FIXTURE_ROOT/live.m3u8" >"$TMP/hls.log" 2>&1 & HLS_PID=$!
for _ in {1..50}; do
  if /usr/bin/curl --silent --fail http://127.0.0.1:19855/health >/dev/null && \
     /usr/bin/curl --silent --fail http://127.0.0.1:19856/health >/dev/null && \
     [[ -f "$CAMDESK_FIXTURE_ROOT/live.m3u8" ]]; then break; fi
  sleep 0.2
done
/usr/bin/curl --silent --fail http://127.0.0.1:19855/health >/dev/null
/usr/bin/curl --silent --fail http://127.0.0.1:19856/health >/dev/null
compile_run ONVIFIntegrationTests Sources/ONVIF.swift Tests/ONVIFIntegrationTests.swift
compile_run NetworkMediaTests Sources/FFmpegLocator.swift Sources/MediaEngine.swift Tests/NetworkMediaTests.swift
printf '\nAll CamDesk tests passed.\n'
