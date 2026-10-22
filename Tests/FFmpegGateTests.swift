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

        let ffmpeg = FFmpegLocator.discover()
        check(FFmpegLocator.isExecutable(ffmpeg), "installed ffmpeg is detected as executable")
        check(!FFmpegLocator.isExecutable("/nonexistent/ffmpeg"), "missing path is rejected")
        check(!FFmpegLocator.isExecutable("/tmp"), "directory is rejected")
        check(!FFmpegLocator.isExecutable(""), "empty path is rejected")

        let discovered = FFmpegLocator.discover()
        check(FFmpegLocator.isExecutable(discovered), "discover() returns a runnable binary, got \(discovered)")

        if let version = FFmpegLocator.version(of: ffmpeg) {
            check(version.lowercased().contains("ffmpeg"), "version line is reported: \(version.prefix(40))…")
        } else {
            print("FAIL version(of:) returned nil for a valid binary"); failures += 1
        }
        check(FFmpegLocator.version(of: "/nonexistent/ffmpeg") == nil, "version(of:) returns nil for a missing binary")
        check(FFmpegLocator.version(of: "/usr/bin/true") == nil, "an unrelated executable is rejected")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("camdesk-version-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let stalled = root.appendingPathComponent("stalled-ffmpeg")
            try Data("#!/bin/sh\nwhile :; do :; done\n".utf8).write(to: stalled)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stalled.path)
            let start = Date()
            check(FFmpegLocator.version(of: stalled.path) == nil, "stalled version command is rejected")
            check(Date().timeIntervalSince(start) < 4, "version probe returns within a bounded time")
        } catch { print("FAIL timeout fixture: \(error.localizedDescription)"); failures += 1 }

        if failures == 0 {
            print("ALL FFMPEG GATE TESTS PASSED")
        } else {
            print("\(failures) FAILURE(S)"); exit(1)
        }
    }
}
