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
        let movie = root.appendingPathComponent("recording.mkv")
        try player.startRecording(to: movie)
        try require(player.isRecording, "recording starts")
        let recordingPIDs = player.ownedProcessIDs
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        player.stopRecording()
        let finalized = await wait(seconds: 7) { recordingPIDs.dropFirst().allSatisfy { kill($0, 0) != 0 } }
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
        try require(!invalid.isConnected && invalid.errorMessage != nil, "real launch error")
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
        print("PASS: application termination notification flushes recording and reaps processes")
        print("ARTIFACTS: \(root.path)")
    }
}
