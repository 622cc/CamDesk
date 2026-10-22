import AppKit
import Foundation
import Darwin

@main struct MediaEngineTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw MediaEngineError.message("TEST FAILED: \(message)") }
    }
    @MainActor static func wait(seconds: Double, until predicate: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }
    @MainActor static func main() async {
        do { try await run(); print("PASS: all media engine tests") }
        catch {
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            print(error.localizedDescription); exit(1)
        }
    }
    @MainActor static func sessionRegressions(root: URL) async throws {
        let script = root.appendingPathComponent("fake-ffmpeg")
        let lock = root.appendingPathComponent("session.lock")
        let overlap = root.appendingPathComponent("overlap")
        let exitCode = root.appendingPathComponent("exit-code")
        let source = """
        #!/usr/bin/env python3
        import os, sys, time, select
        from pathlib import Path
        root = Path(__file__).parent
        lock = root / "session.lock"
        try: lock.mkdir()
        except FileExistsError:
            (root / "overlap").write_text("overlap")
            sys.exit(183)
        frame = (root / "snapshot.jpg").read_bytes()
        recording = "matroska" in sys.argv
        try:
            while True:
                os.write(1, frame)
                if select.select([sys.stdin], [], [], 0.05)[0]:
                    sys.stdin.readline()
                    time.sleep(0.4)
                    break
        finally:
            lock.rmdir()
        sys.exit(int((root / "exit-code").read_text()) if recording else 0)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try "0".write(to: exitCode, atomically: true, encoding: .utf8)
        let player = CameraPlayer(configuration: StreamConfiguration(url: "rtsp://127.0.0.1/fixture", ffmpegPath: script.path))
        defer { player.stop() }
        player.start()
        try require(player.isConnecting, "connecting published before first frame")
        let connected = await wait(seconds: 5) { player.isConnected }
        try require(connected, "non-demo fake preview connects")
        let old = player.ownedProcessIDs
        player.stop(); player.reconnect()
        let reconnected = await wait(seconds: 5) { player.isConnected && old.allSatisfy { kill($0, 0) != 0 } }
        try require(reconnected && player.ownedProcessIDs.count == 1, "immediate reconnect waits old preview exit")
        try player.startRecording(to: root.appendingPathComponent("cancelled.mkv"))
        player.stopRecording(); player.stop(); player.reconnect()
        player.update(configuration: StreamConfiguration(url: "rtsp://127.0.0.1/updated", ffmpegPath: script.path))
        let updated = await wait(seconds: 5) { player.isConnected && !player.isRecording && !player.isFinalizingRecording }
        try require(updated && player.ownedProcessIDs.count == 1, "pending recording cancellation and update restore only one preview")
        var results: [Bool] = []
        player.onRecordingFinished = { _, success in results.append(success) }
        try player.startRecording(to: root.appendingPathComponent("fake-recording.mkv"))
        let recording = await wait(seconds: 5) { player.isConnected && player.status == "录制中" }
        try require(recording && player.ownedProcessIDs.count == 1, "non-demo recording takes single session after preview exits")
        player.stopRecording()
        try require(player.isFinalizingRecording && results.isEmpty, "tail keeps finalizing and no premature finish callback")
        do {
            try player.startRecording(to: root.appendingPathComponent("duplicate.mkv"))
            throw MediaEngineError.message("TEST FAILED: duplicate recording allowed during finalization")
        } catch { try require(error.localizedDescription.contains("请稍候"), "duplicate recording rejected in tail") }
        let finalized = await wait(seconds: 5) { !player.isFinalizingRecording && player.isConnected && results == [true] }
        try require(finalized, "zero exit completes and restores preview")
        try "7".write(to: exitCode, atomically: true, encoding: .utf8)
        try player.startRecording(to: root.appendingPathComponent("failed.mkv"))
        let secondStarted = await wait(seconds: 5) { player.status == "录制中" }
        try require(secondStarted, "second non-demo recording starts")
        player.stopRecording(); player.stop(); player.reconnect()
        let failed = await wait(seconds: 5) { player.isConnected && results == [true, false] }
        try require(failed && player.recordingError?.contains("7") == true && player.status != "录像已保存", "nonzero exit stays visible after preview recovery")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        try require(player.ownedProcessIDs.count == 1 && !FileManager.default.fileExists(atPath: overlap.path), "rapid stop/reconnect never overlaps or resurrects preview")
        let ids = player.ownedProcessIDs; player.stop()
        let clean = await wait(seconds: 5) { ids.allSatisfy { kill($0, 0) != 0 } && !FileManager.default.fileExists(atPath: lock.path) }
        try require(clean, "non-demo session cleanup")
        print("PASS: non-demo single session handoff, cancellation, finalization and real exit reporting")
    }
    @MainActor static func run() async throws {
        var parser = JPEGStreamParser(maximumFrameSize: 32)
        let a = Data([0xff,0xd8,1,2,0xff,0xd9])
        let b = Data([0xff,0xd8,3,0xff,0xd9])
        var frames: [Data] = []
        for byte in Data([0,7,0xff]) + a + b { frames += parser.append(Data([byte])) }
        try require(frames == [a,b], "byte-fragment markers and multiple frames")
        var bounded = JPEGStreamParser(maximumFrameSize: 16)
        _ = bounded.append(Data([0xff,0xd8]) + Data(repeating: 1, count: 100_000))
        try require(bounded.bufferedByteCount <= 16, "parser retains bounded memory")
        try require(bounded.append(a) == [a], "parser recovers after oversized frame")
        var split = JPEGStreamParser()
        try require(split.append(a.dropLast()).isEmpty, "partial EOI")
        try require(split.append(Data([0xd9])) == [a], "split EOI")
        let encoded = try StreamConfiguration(url: "rtsp://example.invalid/stream", username: "a@b", password: "p:/?#%&").inputArguments().last!
        let decoded = URLComponents(string: encoded)!
        try require(decoded.user == "a@b" && decoded.password == "p:/?#%&", "credential URL encoding")
        print("PASS: parser fragmentation, bounded storage, recovery, credential encoding")

        let outputRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CAMDESK_TEST_OUTPUT"] ?? "Tests/artifacts", isDirectory: true)
        let root = outputRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let player = CameraPlayer(configuration: StreamConfiguration(name: "Synthetic demo", isDemo: true))
        player.start()
        try require(!player.isConnected, "connection requires a real frame")
        let arrived = await wait(seconds: 15) { player.isConnected && player.image != nil }
        try require(arrived, "demo first frame: \(player.status), \(player.errorMessage ?? "none")")
        let snapshot = root.appendingPathComponent("snapshot.jpg")
        try player.snapshot(to: snapshot)
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: snapshot))
        try require(bitmap != nil && bitmap!.pixelsWide > 0, "snapshot JPEG decodes")
        print("PASS: actual FFmpeg demo first frame and atomic JPEG snapshot")
        try await sessionRegressions(root: root)
        let originalPreview = player.ownedProcessIDs
        let movie = root.appendingPathComponent("recording.mkv")
        try player.startRecording(to: movie)
        try require(player.isRecording, "recording starts")
        let started = await wait(seconds: 3) { player.ownedProcessIDs.count == 2 }
        try require(started, "demo recording process launches asynchronously")
        let recordingPIDs = player.ownedProcessIDs
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        player.stopRecording()
        try require(player.isFinalizingRecording && !player.isRecording, "recording remains finalizing until actual exit")
        let finalized = await wait(seconds: 7) { !player.isFinalizingRecording && recordingPIDs.dropFirst().allSatisfy { kill($0, 0) != 0 } }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        try require(player.ownedProcessIDs == originalPreview, "demo stop recording preserves original preview without leaking replacement")
        try require(finalized, "recording process exits after stdin q")
        let probe = Process(); let pipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FFPROBE_PATH"] ?? "/opt/homebrew/bin/ffprobe")
        probe.arguments = ["-v", "error", "-show_entries", "format=duration:stream=codec_name,codec_type", "-of", "json", movie.path]
        probe.standardOutput = pipe; probe.standardError = FileHandle.nullDevice
        try probe.run()
        let report = pipe.fileHandleForReading.readDataToEndOfFile(); probe.waitUntilExit()
        try require(probe.terminationStatus == 0, "ffprobe accepts finalized mkv")
        let json = try JSONSerialization.jsonObject(with: report) as! [String: Any]
        let format = json["format"] as? [String: Any]
        try require(Double(format?["duration"] as? String ?? "0")! > 1, "recording duration > 1s")
        let streams = json["streams"] as? [[String: Any]] ?? []
        try require(streams.contains { $0["codec_name"] as? String == "h264" }, "demo recording uses h264")
        do { try player.startRecording(to: movie); throw MediaEngineError.message("TEST FAILED: existing recording overwritten") }
        catch let error as MediaEngineError { try require(error.localizedDescription.contains("尚不存在"), "existing-file rejection") }
        print("PASS: short MKV finalized by q, ffprobe H.264/duration, existing-file protection")

        player.setAudioEnabled(true); player.volume = 0.05
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let audioStarted = player.isAudioEnabled && player.ownedProcessIDs.count == 2
        print(audioStarted ? "PASS: AVAudioEngine + synthetic PCM audio process starts; volume set" : "LIMITATION: audio device unavailable in test host")
        let owned = player.ownedProcessIDs
        player.setAudioEnabled(false)
        player.reconnect()
        let newGeneration = await wait(seconds: 15) { player.isConnected }
        try require(newGeneration, "reconnect returns real frame")
        let allPIDs = owned + player.ownedProcessIDs
        player.stop()
        let clean = await wait(seconds: 7) { allPIDs.allSatisfy { kill($0, 0) != 0 } }
        try require(clean, "all owned subprocesses reaped")
        try require(!player.isConnected && !player.isRecording, "stopped state")
        try? await Task.sleep(nanoseconds: 500_000_000)
        try require(player.ownedProcessIDs.isEmpty, "stop prevents stale reconnect")
        let invalid = CameraPlayer(configuration: StreamConfiguration(ffmpegPath: "/missing/ffmpeg"))
        invalid.start()
        let launchFailed = await wait(seconds: 3) { invalid.errorMessage != nil }
        try require(!invalid.isConnected && launchFailed, "real launch error")
        invalid.stop()
        print("PASS: audio teardown, reconnect generations, stop and no surviving owned processes, launch error")
        player.start()
        let reopened = await wait(seconds: 15) { player.isConnected }
        try require(reopened, "appclose setup frame")
        try player.startRecording(to: root.appendingPathComponent("appclose.mkv"))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let closePIDs = player.ownedProcessIDs
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        try require(closePIDs.allSatisfy { kill($0, 0) != 0 }, "appclose synchronously reaps all owned processes")
        let closeProbe = Process()
        closeProbe.executableURL = probe.executableURL
        closeProbe.arguments = ["-v", "error", "-show_entries", "format=duration", root.appendingPathComponent("appclose.mkv").path]
        closeProbe.standardOutput = FileHandle.nullDevice; closeProbe.standardError = FileHandle.nullDevice
        try closeProbe.run(); closeProbe.waitUntilExit()
        try require(closeProbe.terminationStatus == 0, "ffprobe reads appclose recording after synchronous flush")
        print("PASS: application termination flushes readable recording and reaps processes")
        print("ARTIFACTS: \(root.path)")
    }
}
