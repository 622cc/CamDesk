import Foundation

// Resolves the FFmpeg binary without hard-coding a Homebrew path, so Apple Silicon,
// Intel, MacPorts and manually installed builds all work out of the box.
enum FFmpegLocator {
    static let candidates: [String] = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
        "/Applications/ffmpeg"
    ]

    static func discover() -> String {
        if let fromPath = onSearchPath() { return fromPath }
        if let hit = candidates.first(where: isExecutable) { return hit }
        return candidates[0]
    }

    static func onSearchPath() -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for folder in path.split(separator: ":") {
            let candidate = String(folder) + "/ffmpeg"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Reads the first line of `ffmpeg -version` so the UI can name the build it found.
    static func version(of path: String) -> String? {
        guard isExecutable(path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let firstLine = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? nil : firstLine
    }
}
