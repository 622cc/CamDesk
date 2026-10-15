import Foundation
import AppKit
import Darwin

@main struct NetworkMediaTests {
    @MainActor static func wait(_ message:String,timeout:Double=18,_ condition:()->Bool) async throws {
        let until=Date().addingTimeInterval(timeout)
        while Date()<until {if condition(){return};try await Task.sleep(nanoseconds:100_000_000)}
        throw MediaEngineError.message("Timed out: \(message)")
    }
    @MainActor static func main() async {
        let outputRoot=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CAMDESK_TEST_OUTPUT"] ?? "Tests/artifacts",isDirectory:true)
            let folder=outputRoot.appendingPathComponent("network-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            var recordingURL:URL?
            for (name,address,tcp) in [("RTSP-TCP","rtsp://127.0.0.1:19854/live",true),("RTSP-UDP","rtsp://127.0.0.1:19854/live",false),("HTTP-MJPEG","http://127.0.0.1:19855/mjpeg",true),("HTTP-HLS","http://127.0.0.1:19855/live.m3u8",true)] {
                let player=CameraPlayer(configuration:StreamConfiguration(name:name,url:address,useTCP:tcp))
                player.start()
                try await wait(name+" first frame") {player.isConnected&&player.image != nil}
                let snapshot=folder.appendingPathComponent(name+".jpg")
                try player.snapshot(to:snapshot)
                guard NSImage(contentsOf:snapshot) != nil else {throw MediaEngineError.message("Invalid snapshot")}
                print("PASS \(name) actual frame + JPEG snapshot")
                if name=="RTSP-TCP" {
                    let url=folder.appendingPathComponent("RTSP-recording.mkv")
                    try player.startRecording(to:url)
                    try await Task.sleep(nanoseconds:4_000_000_000)
                    player.stopRecording()
                    try await Task.sleep(nanoseconds:1_000_000_000)
                    let probe=Process();let pipe=Pipe();probe.executableURL=URL(fileURLWithPath:ProcessInfo.processInfo.environment["FFPROBE_PATH"] ?? "/opt/homebrew/bin/ffprobe");probe.arguments=["-v","error","-show_entries","format=duration","-of","default=nw=1:nk=1",url.path];probe.standardOutput=pipe;probe.standardError=FileHandle.nullDevice
                    try probe.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();probe.waitUntilExit()
                    guard probe.terminationStatus==0,let duration=Double(String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)),duration>1 else {throw MediaEngineError.message("RTSP recording did not finalize")}
                    recordingURL=url;print("PASS RTSP actual recording finalized, duration \(duration)")
                }
                if name=="HTTP-HLS" {player.volume=0;player.setAudioEnabled(true);try await Task.sleep(nanoseconds:1_000_000_000);guard player.isAudioEnabled else {throw MediaEngineError.message("HLS audio failed")};player.setAudioEnabled(false);print("PASS HLS audio pipeline")}
                let ids=player.ownedProcessIDs;player.stop()
                try await wait(name+" process cleanup",timeout:6) {ids.allSatisfy{kill($0,0) != 0}}
            }
            if let recordingURL {
                let playback=CameraPlayer(configuration:StreamConfiguration(name:"Saved recording",url:recordingURL.absoluteString))
                playback.start();try await wait("local recording playback") {playback.isConnected}
                try await wait("local EOF",timeout:15) {playback.status=="播放结束"}
                guard playback.errorMessage==nil else {throw MediaEngineError.message("Local file was treated as failure")}
                playback.stop();print("PASS recorded MKV playback + clean EOF")
            }
            NotificationCenter.default.post(name:NSApplication.willTerminateNotification,object:nil)
            print("ALL NETWORK MEDIA TESTS PASSED: \(folder.path)")
        } catch {
            NotificationCenter.default.post(name:NSApplication.willTerminateNotification,object:nil)
            print("FAIL: \(error.localizedDescription)");exit(1)
        }
    }
}
