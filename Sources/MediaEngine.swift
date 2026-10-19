import AppKit
import AVFoundation
import Combine
import Foundation
import Darwin

struct StreamConfiguration {
    var id: UUID
    var name: String
    var url: String
    var username: String
    var password: String
    var useTCP: Bool
    var isDemo: Bool
    var ffmpegPath: String
    init(id: UUID = UUID(), name: String = "Camera", url: String = "", username: String = "", password: String = "", useTCP: Bool = true, isDemo: Bool = false, ffmpegPath: String = FFmpegLocator.discover()) {
        self.id = id; self.name = name; self.url = url; self.username = username; self.password = password
        self.useTCP = useTCP; self.isDemo = isDemo; self.ffmpegPath = ffmpegPath
    }
    func inputArguments() throws -> [String] {
        if isDemo { return ["-re", "-f", "lavfi", "-i", "testsrc2=size=960x540:rate=12"] }
        guard var c = URLComponents(string: url), let scheme = c.scheme?.lowercased(), ["rtsp", "rtsps", "http", "https", "rtmp", "srt", "file"].contains(scheme) else { throw MediaEngineError.message("请输入有效的视频地址。") }
        if scheme == "file" {
            guard let file = c.url, file.isFileURL, FileManager.default.fileExists(atPath:file.path) else { throw MediaEngineError.message("录像文件不存在。") }
            return ["-re", "-i", file.path]
        }
        guard c.host != nil else { throw MediaEngineError.message("视频地址缺少主机。") }
        if !username.isEmpty { c.user = username; c.password = password }
        guard let address = c.url?.absoluteString else { throw MediaEngineError.message("视频地址格式错误。") }
        if scheme == "rtsp" || scheme == "rtsps" {
            return ["-rtsp_transport", useTCP ? "tcp" : "udp", "-timeout", "10000000", "-i", address]
        }
        return ["-rw_timeout", "10000000", "-i", address]
    }
}

enum MediaEngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// Incremental framing with a hard limit, including split SOI/EOI markers.
struct JPEGStreamParser {
    let maximumFrameSize: Int
    private(set) var bufferedByteCount = 0
    private var bytes: [UInt8] = []
    private var inFrame = false
    private var previous: UInt8 = 0
    init(maximumFrameSize: Int = 8 * 1024 * 1024) { self.maximumFrameSize = max(4, maximumFrameSize) }
    mutating func append(_ data: Data) -> [Data] {
        var frames: [Data] = []
        for byte in data {
            if !inFrame {
                if previous == 0xff && byte == 0xd8 { bytes = [0xff, 0xd8]; inFrame = true }
            } else {
                bytes.append(byte)
                if previous == 0xff && byte == 0xd9 { frames.append(Data(bytes)); bytes.removeAll(keepingCapacity: true); inFrame = false }
                else if bytes.count >= maximumFrameSize { bytes.removeAll(keepingCapacity: true); inFrame = false }
            }
            previous = byte
        }
        bufferedByteCount = bytes.count
        return frames
    }
}

private final class MediaProcess: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [Int32: MediaProcess] = [:]
    static func shutdownAll() {
        registryLock.lock(); let owned = Array(registry.values); registryLock.unlock()
        owned.forEach { $0.stop() }
        // Application termination must finish q/container flushing before the host exits.
        owned.forEach { $0.process.waitUntilExit() }
    }
    let process = Process()
    let output = Pipe()
    private let errors = Pipe()
    private let input = Pipe()
    private let lock = NSLock()
    private var stopping = false
    var pid: Int32 { process.processIdentifier }
    init(path: String, arguments: [String], onExit: @escaping (Int32) -> Void) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw MediaEngineError.message("FFmpeg 路径不存在或不可执行。") }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-loglevel", "error"] + arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] process in
            self?.closeHandles()
            Self.registryLock.lock(); Self.registry.removeValue(forKey: process.processIdentifier); Self.registryLock.unlock()
            onExit(process.terminationStatus)
        }
        do { try process.run() } catch { closeHandles(); throw MediaEngineError.message("FFmpeg 启动失败，请检查可执行路径。") }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        Self.registryLock.lock()
        if process.isRunning { Self.registry[pid] = self }
        Self.registryLock.unlock()
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
    }
    private func closeHandles() {
        errors.fileHandleForReading.readabilityHandler = nil
        try? errors.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
    }
    func read(_ consume: @escaping (Data) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { try? output.fileHandleForReading.close() }
            while true {
                do { guard let data = try output.fileHandleForReading.read(upToCount: 65536), !data.isEmpty else { break }; consume(data) }
                catch { break }
            }
        }
    }
    func stop() {
        lock.lock(); if stopping { lock.unlock(); return }; stopping = true; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            if process.isRunning { try? input.fileHandleForWriting.write(contentsOf: Data("q\n".utf8)) }
            try? input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { process.terminate() }
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { kill(pid, SIGKILL) }
            process.waitUntilExit(); closeHandles()
        }
    }
    deinit { if process.isRunning { process.terminate() } }
}

private final class PCMOutput: @unchecked Sendable {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private let slots = DispatchSemaphore(value: 8)
    private let lock = NSLock()
    private var stopped = false
    private var pending = Data()
    init() throws { engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format); try engine.start(); player.play() }
    func feed(_ data: Data) {
        pending.append(data)
        let block = 4096
        while pending.count >= block {
            let chunk = pending.prefix(block); pending.removeFirst(block)
            guard slots.wait(timeout: .now() + 0.2) == .success else { continue }
            lock.lock()
            if stopped { lock.unlock(); slots.signal(); return }
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block / 4)) {
                buffer.frameLength = buffer.frameCapacity
                _ = chunk.withUnsafeBytes { raw in memcpy(buffer.floatChannelData![0], raw.baseAddress!, block) }
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [slots] _ in slots.signal() }
            } else { slots.signal() }
            lock.unlock()
        }
    }
    func setVolume(_ value: Float) { lock.lock(); player.volume = min(1, max(0, value)); lock.unlock() }
    func stop() { lock.lock(); stopped = true; player.stop(); engine.stop(); lock.unlock() }
}

@MainActor final class CameraPlayer: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var status = "未连接"
    @Published private(set) var isConnected = false
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?
    @Published var volume: Float = 1 { didSet { audioOutput?.setVolume(volume) } }
    @Published private(set) var isAudioEnabled = false
    private var configuration: StreamConfiguration
    private var preview: MediaProcess?
    private var recording: MediaProcess?
    private var audio: MediaProcess?
    private var audioOutput: PCMOutput?
    private var generation = UUID()
    private var recordingGeneration = UUID()
    private var audioGeneration = UUID()
    private var wantsRunning = false
    private var retryCount = 0
    private var reconnectTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var currentJPEG: Data?
    private var closeObserver: NSObjectProtocol?
    var ownedProcessIDs: [Int32] { [preview, recording, audio].compactMap { $0?.pid } }
    init(configuration: StreamConfiguration) {
        self.configuration = configuration
        closeObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(); MediaProcess.shutdownAll() }
        }
    }
    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        reconnectTask?.cancel(); timeoutTask?.cancel(); preview?.stop(); recording?.stop(); audio?.stop(); audioOutput?.stop()
    }
    func start() { guard !wantsRunning else { return }; wantsRunning = true; retryCount = 0; launchPreview() }
    func stop() {
        wantsRunning = false; generation = UUID(); reconnectTask?.cancel(); reconnectTask = nil; timeoutTask?.cancel(); timeoutTask = nil
        preview?.stop(); preview = nil; stopRecording(); stopAudio(); isConnected = false; status = "已停止"
    }
    func reconnect() { stop(); start() }
    func update(configuration: StreamConfiguration) {
        let running = wantsRunning; stop(); self.configuration = configuration; image = nil; currentJPEG = nil; errorMessage = nil
        if running { start() }
    }
    private func launchPreview() {
        generation = UUID(); let token = generation
        isConnected = false; status = "连接中…"; errorMessage = nil
        do {
            let args = try configuration.inputArguments() + ["-an", "-vf", "fps=12,scale=1280:720:force_original_aspect_ratio=decrease", "-c:v", "mjpeg", "-q:v", "4", "-f", "image2pipe", "pipe:1"]
            let process = try MediaProcess(path: configuration.ffmpegPath, arguments: args) { [weak self] code in Task { @MainActor in self?.previewEnded(token: token, reason: "视频流已断开（FFmpeg \(code)）。", exitCode: code) } }
            preview = process
            var parser = JPEGStreamParser(); var lastDelivery = Date.distantPast
            let deliverySlot = DispatchSemaphore(value: 1)
            process.read { [weak self] data in
                for jpeg in parser.append(data) {
                    guard Date().timeIntervalSince(lastDelivery) >= 1.0 / 12.0,
                          deliverySlot.wait(timeout: .now()) == .success else { continue }
                    guard let bitmap = NSBitmapImageRep(data: jpeg), bitmap.cgImage != nil else { deliverySlot.signal(); continue }
                    lastDelivery = Date()
                    Task { @MainActor [weak self] in
                        defer { deliverySlot.signal() }
                        guard let self, self.generation == token, self.wantsRunning else { return }
                        let frame = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)); frame.addRepresentation(bitmap)
                        self.image = frame; self.currentJPEG = jpeg
                        let first = !self.isConnected; self.isConnected = true; self.status = "已连接"; self.errorMessage = nil
                        if first { self.timeoutTask?.cancel(); if self.isAudioEnabled { self.launchAudio() } }
                    }
                }
            }
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled, let self, self.generation == token, !self.isConnected else { return }
                self.preview?.stop(); self.previewEnded(token: token, reason: "连接超时：12 秒内未收到有效视频帧。")
            }
        } catch { previewEnded(token: token, reason: error.localizedDescription) }
    }
    private func previewEnded(token: UUID, reason: String, exitCode: Int32? = nil) {
        guard generation == token, wantsRunning else { return }
        generation = UUID(); timeoutTask?.cancel(); preview?.stop(); preview = nil; isConnected = false; stopAudio(); errorMessage = reason
        if URL(string:configuration.url)?.isFileURL == true {
            wantsRunning=false;status=exitCode == 0 ? "播放结束" : "播放失败";errorMessage=exitCode == 0 ? nil : reason;return
        }
        guard retryCount < 5 else { status = "连接失败"; wantsRunning = false; return }
        retryCount += 1; status = "等待重连（\(retryCount)/5）"; let delay = min(8, retryCount * 2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.wantsRunning else { return }; self.launchPreview()
        }
    }
    func snapshot(to url: URL) throws {
        guard let jpeg = currentJPEG, let bitmap = NSBitmapImageRep(data: jpeg), let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else { throw MediaEngineError.message("尚无可保存的视频帧。") }
        try data.write(to: url, options: .atomic)
    }
    /// Single-session recording. Many cameras allow one RTSP client only, so recording
    /// takes the connection over: preview and audio step aside, one FFmpeg reads the
    /// camera, keeps the screen fed, and writes the recording from the same decoders.
    /// Preview quality is unchanged; recording keeps the original video bitstream.
    func startRecording(to url: URL) throws {
        guard recording == nil else { throw MediaEngineError.message("正在录制。") }
        guard url.isFileURL, url.pathExtension.lowercased() == "mkv", !FileManager.default.fileExists(atPath: url.path) else { throw MediaEngineError.message("请指定尚不存在的 .mkv 文件。") }
        guard wantsRunning else { throw MediaEngineError.message("请先连接摄像头，再开始录像。") }

        if configuration.isDemo {
            var args = (try configuration.inputArguments()) + ["-map", "0:v:0", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-f", "matroska", url.path]
            args = ["-n"] + args
            recordingGeneration = UUID(); let demoToken = recordingGeneration
            let demo = try MediaProcess(path: configuration.ffmpegPath, arguments: args) { [weak self] code in
                Task { @MainActor in
                    guard let self, self.recordingGeneration == demoToken else { return }
                    self.recording = nil; self.isRecording = false
                    if code != 0 { self.errorMessage = "录像写入失败（FFmpeg \(code)）。" }
                }
            }
            recording = demo; isRecording = true; demo.read { _ in }
            return
        }

        // Step aside: release every other camera session before recording starts.
        stopAudio()
        preview?.stop(); preview = nil
        image = nil; currentJPEG = nil; isConnected = false
        generation = UUID(); timeoutTask?.cancel(); reconnectTask?.cancel()

        var args = try configuration.inputArguments()
        args += ["-an", "-vf", "fps=12,scale=1280:720:force_original_aspect_ratio=decrease", "-c:v", "mjpeg", "-q:v", "4", "-f", "image2pipe", "pipe:1"]
        args += ["-map", "0:v:0", "-c", "copy", "-f", "matroska", url.path]
        args = ["-n"] + args

        recordingGeneration = UUID(); let token = recordingGeneration
        let process = try MediaProcess(path: configuration.ffmpegPath, arguments: args) { [weak self] code in
            Task { @MainActor in
                guard let self, self.recordingGeneration == token else { return }
                let wasRecording = self.isRecording
                self.recording = nil; self.isRecording = false
                if code != 0 {
                    self.errorMessage = code == 183
                        ? "摄像头不接受第二条连接，录像未能开始。请关闭手机 App 等其它观看端后重试。"
                        : "录像写入失败（FFmpeg \(code)）。"
                } else if wasRecording {
                    self.errorMessage = nil
                }
                self.resumePreviewAfterRecording()
            }
        }
        recording = process; isRecording = true
        var parser = JPEGStreamParser(); var lastDelivery = Date.distantPast
        let deliverySlot = DispatchSemaphore(value: 1)
        process.read { [weak self] data in
            for jpeg in parser.append(data) {
                guard Date().timeIntervalSince(lastDelivery) >= 1.0 / 12.0,
                      deliverySlot.wait(timeout: .now()) == .success else { continue }
                guard let bitmap = NSBitmapImageRep(data: jpeg), bitmap.cgImage != nil else { deliverySlot.signal(); continue }
                lastDelivery = Date()
                Task { @MainActor [weak self] in
                    defer { deliverySlot.signal() }
                    guard let self, self.recordingGeneration == token, self.wantsRunning else { return }
                    let frame = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)); frame.addRepresentation(bitmap)
                    self.image = frame; self.currentJPEG = jpeg; self.isConnected = true; self.status = "录制中"
                }
            }
        }
    }
    private func resumePreviewAfterRecording() {
        guard wantsRunning, recording == nil else { return }
        generation = UUID(); retryCount = 0
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, self.wantsRunning, self.recording == nil else { return }
            self.launchPreview()
        }
    }
    func stopRecording() {
        guard recording != nil || isRecording else { return }
        recordingGeneration = UUID(); recording?.stop(); recording = nil; isRecording = false
        status = "录像已保存"
        resumePreviewAfterRecording()
    }
    /// Audio only plays while no recording owns the single camera session.
    func setAudioEnabled(_ enabled: Bool) {
        if enabled && recording != nil {
            errorMessage = "录制期间无法同时监听音频：摄像头只允许一条连接。请先停止录像。"
            isAudioEnabled = false; return
        }
        isAudioEnabled = enabled
        if enabled && isConnected { launchAudio() } else if !enabled { stopAudio() }
    }
    private func stopAudio() { audioGeneration = UUID(); audio?.stop(); audio = nil; audioOutput?.stop(); audioOutput = nil }
    private func launchAudio() {
        stopAudio(); audioGeneration = UUID(); let token = audioGeneration
        do {
            let output = try PCMOutput(); output.setVolume(volume)
            var input = try configuration.inputArguments()
            if configuration.isDemo { input = ["-re", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"] }
            let process = try MediaProcess(path: configuration.ffmpegPath, arguments: input + ["-vn", "-map", "0:a:0", "-ac", "1", "-ar", "48000", "-f", "f32le", "pipe:1"]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.audioGeneration == token else { return }; self.stopAudio(); self.isAudioEnabled = false; self.errorMessage = "音频流已停止，源可能没有音轨。"
                }
            }
            audioOutput = output; audio = process; process.read { data in output.feed(data) }
        } catch { stopAudio(); isAudioEnabled = false; errorMessage = "音频输出启动失败，请检查输出设备和 FFmpeg。" }
    }
}
