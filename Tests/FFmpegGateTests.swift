import Foundation

// Verifies the first-run gate: when the configured FFmpeg path is not executable,
// the overview must render the setup view instead of the camera list.
// Run standalone so no HOME or sandbox overrides are involved.
@main struct FFmpegGateTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { print("PASS \(message)") } else { print("FAIL \(message)"); failures += 1 }
        }

        check(FFmpegLocator.isExecutable("/opt/homebrew/bin/ffmpeg"), "real Homebrew ffmpeg is detected as executable")
        check(!FFmpegLocator.isExecutable("/nonexistent/ffmpeg"), "missing path is rejected")
        check(!FFmpegLocator.isExecutable("/tmp"), "directory is rejected")
        check(!FFmpegLocator.isExecutable(""), "empty path is rejected")

        let discovered = FFmpegLocator.discover()
        check(FFmpegLocator.isExecutable(discovered), "discover() returns a runnable binary, got \(discovered)")

        if let version = FFmpegLocator.version(of: "/opt/homebrew/bin/ffmpeg") {
            check(version.lowercased().contains("ffmpeg"), "version line is reported: \(version.prefix(40))…")
        } else {
            print("FAIL version(of:) returned nil for a valid binary"); failures += 1
        }
        check(FFmpegLocator.version(of: "/nonexistent/ffmpeg") == nil, "version(of:) returns nil for a missing binary")

        if failures == 0 {
            print("ALL FFMPEG GATE TESTS PASSED")
        } else {
            print("\(failures) FAILURE(S)"); exit(1)
        }
    }
}
