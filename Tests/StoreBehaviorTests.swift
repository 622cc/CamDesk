import AppKit
import Darwin
import Foundation

@main struct StoreBehaviorTests {
    @MainActor static func wait(_ message: String, seconds: Double = 15, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw StringError(message: "Timed out: \(message)")
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw StringError(message: "FAILED: \(message)") }
    }
    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("camdesk-store-\(UUID().uuidString)")
        var store: AppStore?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let stateURL = root.appendingPathComponent("configuration.json")
            var preferences = Preferences()
            preferences.captureDirectory = root.appendingPathComponent("media").path
            let camera = CameraRecord(name: "Store fixture", isDemo: true)
            try JSONEncoder().encode(PersistedState(cameras: [camera], preferences: preferences)).write(to: stateURL)
            let app = AppStore(stateURL: stateURL)
            store = app
            app.startSavedCameras()
            guard let player = app.players[camera.id] else { throw StringError(message: "Missing test player") }
            try await wait("demo frame") { player.isConnected }
            app.toggleRecording(camera)
            try await wait("recording process") { player.ownedProcessIDs.count == 2 }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            app.toggleRecording(camera)
            try require(player.isFinalizingRecording, "stop remains in saving state")
            try require(app.toast != "录像已保存", "no success toast before finalization")
            try await wait("recording completion updates library") { !player.isFinalizingRecording && app.toast == "录像已保存" && app.library.contains(where: \.isVideo) }
            print("PASS store updates recording library and toast only after finalization")

            let originalIDs = player.ownedProcessIDs
            let alternate = root.appendingPathComponent("ffmpeg")
            try FileManager.default.createSymbolicLink(atPath: alternate.path, withDestinationPath: preferences.ffmpegPath)
            app.preferences.ffmpegPath = alternate.path
            app.savePreferences()
            try await wait("saved engine applied to active player") {
                app.toast == "设置已保存" && player.isConnected && !player.ownedProcessIDs.isEmpty && originalIDs.allSatisfy { kill($0, 0) != 0 }
            }
            let saved = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: stateURL))
            try require(saved.preferences.ffmpegPath == alternate.path, "new engine persisted")
            print("PASS changing engine reconnects active players and reaps old processes")

            app.preferences.ffmpegPath = "/usr/bin/true"
            app.savePreferences()
            try await wait("invalid executable rejected") { app.issue != nil }
            let unchanged = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: stateURL))
            try require(unchanged.preferences.ffmpegPath == alternate.path, "invalid executable not persisted")
            app.shutdown()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            print("ALL STORE BEHAVIOR TESTS PASSED")
        } catch {
            store?.shutdown()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }
}
