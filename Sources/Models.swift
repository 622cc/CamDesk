import Foundation
import AppKit
import Security
import Combine

struct CameraRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var group = "默认分组"
    var hostHint = ""
    var isFavorite = false
    var isDemo = false
    var autoConnect = true
    var useTCP = true
    var profileToken = ""
}
struct ConnectionSecrets: Codable {
    var streamURL = ""
    var onvifEndpoint = ""
    var username = ""
    var password = ""
}
struct CameraDraft: Identifiable {
    var id: UUID { camera.id }
    var camera: CameraRecord
    var connection: ConnectionSecrets
    init(camera: CameraRecord = CameraRecord(name: "新摄像头"), connection: ConnectionSecrets = ConnectionSecrets()) { self.camera = camera; self.connection = connection }
}
struct Preferences: Codable {
    var ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    var captureDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/CamDesk").path
}
struct ArchiveCamera: Codable {
    var camera: CameraRecord
    var streamURL: String
    var onvifEndpoint: String
    var username: String
}
struct CameraArchive: Codable { var version = 1; var cameras: [ArchiveCamera] }
struct PersistedState: Codable { var version = 1; var cameras: [CameraRecord]; var preferences: Preferences }
struct LibraryItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let created: Date
    let size: Int64
    var isVideo: Bool { ["mkv", "mp4", "mov"].contains(url.pathExtension.lowercased()) }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}
struct AppIssue: Identifiable { let id = UUID(); let message: String }
struct StringError: LocalizedError { let message: String; var errorDescription: String? { message } }

final class CredentialVault {
    static let service = "com.github.622cc.camdesk.connections"
    private static let legacyService = "local.camdesk.mac.connections"
    private func read(_ id: UUID, service: String) throws -> ConnectionSecrets? {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:id.uuidString, kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StringError(message: "钥匙串读取失败（\(status)），请在编辑中重新填写连接信息。") }
        return try JSONDecoder().decode(ConnectionSecrets.self, from:data)
    }
    func load(_ id: UUID) throws -> ConnectionSecrets? {
        if let value = try read(id, service:Self.service) { return value }
        guard let legacy = try read(id, service:Self.legacyService) else { return nil }
        try save(legacy, id:id)
        return legacy
    }
    func save(_ value: ConnectionSecrets, id: UUID) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:Self.service,kSecAttrAccount as String:id.uuidString]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw StringError(message:"连接信息保存到钥匙串失败（\(result)）。") }
        } else if update != errSecSuccess { throw StringError(message:"连接信息更新失败（\(update)）。") }
    }
    func remove(_ id: UUID) throws {
        for service in [Self.service,Self.legacyService] {
            let status = SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StringError(message:"钥匙串删除失败（\(status)）。") }
        }
    }
}

@MainActor final class AppStore: ObservableObject {
    @Published var cameras: [CameraRecord] = []
    @Published var preferences = Preferences()
    @Published var players: [UUID:CameraPlayer] = [:]
    @Published var selectedID: UUID? { didSet { if oldValue != selectedID { presets=[];viewZoom=1 } } }
    @Published var viewZoom:Double = 1
    @Published var section = "live"
    @Published var focusedView = true
    @Published var controlsVisible = true
    @Published var search = ""
    @Published var groupFilter = "全部摄像头"
    @Published var issue: AppIssue?
    @Published var toast = ""
    @Published var library: [LibraryItem] = []
    @Published var editDraft: CameraDraft?
    @Published var discoverVisible = false
    @Published var playback: LibraryItem?
    @Published var ptzBusy = false
    @Published var ptzSpeed = 0.45
    @Published var presets: [ONVIFPreset] = []
    private let vault = CredentialVault()
    private var connections: [UUID:ConnectionSecrets] = [:]
    private var ptzClients: [UUID:ONVIFClient] = [:]
    private var ptzTasks: [UUID:Task<Void,Never>] = [:]
    private var stopping = false
    private let stateURL: URL
    init() {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let base = support.appendingPathComponent("com.github.622cc.camdesk",isDirectory:true)
        stateURL = base.appendingPathComponent("configuration.json")
        let legacy = support.appendingPathComponent("local.camdesk.mac",isDirectory:true).appendingPathComponent("configuration.json")
        if !FileManager.default.fileExists(atPath:stateURL.path),FileManager.default.fileExists(atPath:legacy.path) {
            do {try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true);try FileManager.default.copyItem(at:legacy,to:stateURL)}
            catch {issue=AppIssue(message:"旧版摄像头配置迁移失败：\(error.localizedDescription)")}
        }
        if FileManager.default.fileExists(atPath:stateURL.path) {
            do {
                let state = try JSONDecoder().decode(PersistedState.self, from:Data(contentsOf:stateURL))
                guard state.version == 1 else { throw StringError(message:"配置版本不受支持，原配置已保留。") }
                cameras = state.cameras; preferences = state.preferences
            } catch { issue = AppIssue(message:"读取 CamDesk 配置失败：\(error.localizedDescription)") }
        }
        selectedID = cameras.first(where: { !$0.isDemo })?.id ?? cameras.first?.id
        for camera in cameras {
            players[camera.id]=CameraPlayer(configuration:StreamConfiguration(id:camera.id,name:camera.name,isDemo:camera.isDemo,ffmpegPath:preferences.ffmpegPath))
        }
        NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }
    var groups: [String] { Array(Set(cameras.map(\.group))).sorted() }
    var visibleCameras: [CameraRecord] {
        cameras.filter { c in
            (groupFilter == "全部摄像头" || (groupFilter == "收藏" ? c.isFavorite : c.group == groupFilter)) && (search.isEmpty || "\(c.name) \(c.group) \(c.hostHint)".localizedCaseInsensitiveContains(search))
        }
    }
    var selected: CameraRecord? { cameras.first { $0.id == selectedID } }
    var activeCount: Int { players.values.filter(\.isConnected).count }
    var recordingCount: Int { players.values.filter(\.isRecording).count }
    func report(_ error: Error) { issue = AppIssue(message:error.localizedDescription) }
    func notify(_ text: String) {
        toast = text
        Task { try? await Task.sleep(nanoseconds:3_000_000_000); if toast == text { toast = "" } }
    }
    func persist() throws {
        let manager = FileManager.default
        try manager.createDirectory(at:stateURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        let data = try JSONEncoder().encode(PersistedState(cameras:cameras,preferences:preferences))
        if manager.fileExists(atPath:stateURL.path) {
            let backup = stateURL.deletingLastPathComponent().appendingPathComponent("configuration-\(UUID().uuidString).backup.json")
            try manager.copyItem(at:stateURL,to:backup)
        }
        try data.write(to:stateURL,options:.atomic)
    }
    func connection(for camera: CameraRecord) throws -> ConnectionSecrets {
        if let existing = connections[camera.id] { return existing }
        let result = try vault.load(camera.id) ?? ConnectionSecrets()
        connections[camera.id] = result
        return result
    }
    func configuration(for camera: CameraRecord) throws -> StreamConfiguration {
        let c = try connection(for:camera)
        return StreamConfiguration(id:camera.id,name:camera.name,url:c.streamURL,username:c.username,password:c.password,useTCP:camera.useTCP,isDemo:camera.isDemo,ffmpegPath:preferences.ffmpegPath)
    }
    func player(for camera: CameraRecord) -> CameraPlayer? {
        if let player = players[camera.id] { return player }
        do { let player = CameraPlayer(configuration:try configuration(for:camera)); players[camera.id]=player; return player }
        catch { report(error); return nil }
    }
    func reconnect(_ camera:CameraRecord) {
        Task { [weak self] in
            guard let self else{return}
            do {
                if self.connections[camera.id]==nil {
                    let id=camera.id
                    let loaded=try await Task.detached {try CredentialVault().load(id) ?? ConnectionSecrets()}.value
                    guard self.cameras.contains(where:{$0.id==id}),!self.stopping else{return}
                    self.connections[id]=loaded
                }
                if let player=self.players[camera.id] {player.update(configuration:try self.configuration(for:camera));player.start()}
            } catch {self.report(error)}
        }
    }
    func startSavedCameras() {
        for c in cameras where c.autoConnect { reconnect(c) }
    }
    func save(_ draft: CameraDraft) throws {
        var camera = draft.camera
        camera.name = camera.name.trimmingCharacters(in:.whitespacesAndNewlines)
        camera.group = camera.group.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !camera.name.isEmpty else { throw StringError(message:"请输入摄像头名称。") }
        if camera.group.isEmpty { camera.group = "默认分组" }
        var connection = draft.connection
        connection.streamURL = connection.streamURL.trimmingCharacters(in:.whitespacesAndNewlines)
        if !camera.isDemo {
            guard var components = URLComponents(string:connection.streamURL),let scheme = components.scheme?.lowercased(),["rtsp","rtsps","http","https","rtmp","srt"].contains(scheme),let host=components.host,!host.isEmpty else { throw StringError(message:"请输入有效的视频地址，例如 rtsp://192.168.1.10:554/stream1。") }
            if let user=components.user,connection.username.isEmpty { connection.username=user.removingPercentEncoding ?? user }
            if let password=components.password,connection.password.isEmpty { connection.password=password.removingPercentEncoding ?? password }
            components.user=nil;components.password=nil
            connection.streamURL=components.string ?? connection.streamURL
            camera.hostHint=host
        } else { camera.hostHint="本地生成 · 无网络连接" }
        if !connection.onvifEndpoint.isEmpty {
            guard let url=URL(string:connection.onvifEndpoint),["http","https"].contains(url.scheme?.lowercased() ?? ""),url.host != nil else { throw StringError(message:"ONVIF 服务地址应为 http://摄像头地址/onvif/device_service。") }
        }
        try vault.save(connection,id:camera.id)
        connections[camera.id]=connection
        let previous=cameras
        if let i=cameras.firstIndex(where:{$0.id==camera.id}) { cameras[i]=camera } else { cameras.append(camera) }
        do { try persist() } catch { cameras=previous;throw error }
        players[camera.id]?.stop()
        players[camera.id]=CameraPlayer(configuration:try configuration(for:camera))
        ptzClients[camera.id]=nil
        if camera.autoConnect { players[camera.id]?.start() }
        selectedID=camera.id;section="live";focusedView=true;notify("已保存 \(camera.name)")
    }
    func addDemo() {
        do { try save(CameraDraft(camera:CameraRecord(name:"本地演示 \(cameras.filter(\.isDemo).count+1)",group:"演示源",isDemo:true))) }
        catch { report(error) }
    }
    func edit(_ camera: CameraRecord) {
        do { editDraft=CameraDraft(camera:camera,connection:try connection(for:camera)) }
        catch { report(error) }
    }
    func toggleFavorite(_ camera: CameraRecord) {
        guard let i=cameras.firstIndex(where:{$0.id==camera.id}) else{return}
        cameras[i].isFavorite.toggle(); do {try persist()} catch {report(error)}
    }
    func remove(_ camera: CameraRecord) {
        let alert=NSAlert();alert.messageText="删除“\(camera.name)”？";alert.informativeText="只删除 CamDesk 中的配置和对应钥匙串连接信息，已保存的截图与录像会保留。";alert.addButton(withTitle:"删除");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        do {
            try vault.remove(camera.id)
            players[camera.id]?.stop();players[camera.id]=nil;connections[camera.id]=nil
            cameras.removeAll{$0.id==camera.id};if selectedID==camera.id{selectedID=cameras.first?.id}
            try persist()
        } catch { report(error) }
    }
    func outputURL(camera: CameraRecord, extension ext: String) throws -> URL {
        let folder=URL(fileURLWithPath:preferences.captureDirectory,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let formatter=DateFormatter();formatter.dateFormat="yyyyMMdd-HHmmss-SSS"
        let safe=camera.name.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        return folder.appendingPathComponent("\(safe)-\(formatter.string(from:Date())).\(ext)")
    }
    func snapshot(_ camera: CameraRecord) {
        do { guard let p=player(for:camera) else{return};let url=try outputURL(camera:camera,extension:"jpg");try p.snapshot(to:url);notify("截图已保存");refreshLibrary() }
        catch {report(error)}
    }
    func toggleRecording(_ camera: CameraRecord) {
        guard let player=player(for:camera) else{return}
        do {if player.isRecording {player.stopRecording();notify("录像正在保存")} else {try player.startRecording(to:outputURL(camera:camera,extension:"mkv"));notify("已开始录像")}}
        catch {report(error)}
        Task {try? await Task.sleep(nanoseconds:1_000_000_000);refreshLibrary()}
    }
    func chooseOutputDirectory() {
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true;panel.prompt="选择保存位置"
        if panel.runModal() == .OK,let url=panel.url {preferences.captureDirectory=url.path;do{try persist();refreshLibrary()}catch{report(error)}}
    }
    func refreshLibrary() {
        let folder=URL(fileURLWithPath:preferences.captureDirectory,isDirectory:true)
        guard FileManager.default.fileExists(atPath:folder.path) else {library=[];return}
        do {
            let files=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.creationDateKey,.fileSizeKey],options:.skipsHiddenFiles)
            library=files.filter{["mkv","mp4","mov","jpg","jpeg","png"].contains($0.pathExtension.lowercased())}.map {url in let v=try? url.resourceValues(forKeys:[.creationDateKey,.fileSizeKey]);return LibraryItem(url:url,created:v?.creationDate ?? .distantPast,size:Int64(v?.fileSize ?? 0))}.sorted{$0.created>$1.created}
        } catch {report(error)}
    }
    func reveal(_ url:URL) {NSWorkspace.shared.activateFileViewerSelecting([url])}
    func exportConfiguration() {
        let panel=NSSavePanel();panel.nameFieldStringValue="CamDesk.camdesk";panel.message="导出名称、流地址、ONVIF 地址和用户名，不导出钥匙串密码。流地址本身可能包含访问令牌，请妥善保存。"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let entries=try cameras.map {camera -> ArchiveCamera in let c=try connection(for:camera);return ArchiveCamera(camera:camera,streamURL:c.streamURL,onvifEndpoint:c.onvifEndpoint,username:c.username)}
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(CameraArchive(cameras:entries)).write(to:url,options:.atomic);notify("配置已导出，密码留在钥匙串")
        } catch {report(error)}
    }
    func importConfiguration() {
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let data=try Data(contentsOf:url);guard data.count<=4_000_000 else {throw StringError(message:"配置文件超过4MB。")}
            let archive=try JSONDecoder().decode(CameraArchive.self,from:data)
            guard archive.version==1 && archive.cameras.count<=100 else {throw StringError(message:"配置版本不受支持，或摄像头超过100台。")}
            var count=0
            for entry in archive.cameras {
                var camera=entry.camera;camera.id=UUID();camera.autoConnect=false
                try save(CameraDraft(camera:camera,connection:ConnectionSecrets(streamURL:entry.streamURL,onvifEndpoint:entry.onvifEndpoint,username:entry.username)))
                count+=1
            }
            notify("已导入 \(count) 台摄像头，请编辑补充密码后连接")
        } catch {report(error)}
    }
    func onvifClient(for camera:CameraRecord) throws -> ONVIFClient {
        if let client=ptzClients[camera.id]{return client}
        let c=try connection(for:camera)
        guard let endpoint=URL(string:c.onvifEndpoint),["http","https"].contains(endpoint.scheme ?? "") else {throw StringError(message:"请在编辑摄像头中设置 ONVIF 服务地址，并读取视频配置。")}
        let client=ONVIFClient(endpoint:endpoint,credentials:ONVIFCredentials(username:c.username,password:c.password));ptzClients[camera.id]=client;return client
    }
    func ptz(pan:Double=0,tilt:Double=0,zoom:Double=0) {
        guard !ptzBusy,let camera=selected else{return}
        guard !camera.profileToken.isEmpty else{issue=AppIssue(message:"请先在编辑中读取并选择 ONVIF 视频配置。");return}
        ptzTasks[camera.id]?.cancel()
        ptzTasks[camera.id]=Task { [weak self] in
            guard let self else{return};self.ptzBusy=true
            do {
                let client=try self.onvifClient(for:camera)
                try await client.move(profileToken:camera.profileToken,pan:pan*self.ptzSpeed,tilt:tilt*self.ptzSpeed,zoom:zoom*self.ptzSpeed)
                try? await Task.sleep(nanoseconds:250_000_000)
                try await client.stop(profileToken:camera.profileToken)
            } catch {self.report(error)}
            self.ptzBusy=false
        }
    }
    func stopPTZ() {
        guard let camera=selected else{return};ptzTasks[camera.id]?.cancel()
        Task { do {try await onvifClient(for:camera).stop(profileToken:camera.profileToken)}catch{report(error)};ptzBusy=false }
    }
    func homePTZ() {
        guard let camera=selected else{return}
        Task {do{try await onvifClient(for:camera).home(profileToken:camera.profileToken)}catch{report(error)}}
    }
    func fetchPresets() {
        guard let camera=selected else{return}
        Task {do{presets=try await onvifClient(for:camera).presets(profileToken:camera.profileToken);if presets.isEmpty{notify("该设备没有返回预置位")}}catch{report(error)}}
    }
    func gotoPreset(_ preset:ONVIFPreset) {
        guard let camera=selected else{return}
        Task {do{try await onvifClient(for:camera).gotoPreset(profileToken:camera.profileToken,presetToken:preset.id)}catch{report(error)}}
    }
    func toggleAudio(_ player:CameraPlayer) {
        if !player.isAudioEnabled { players.values.filter { $0 !== player }.forEach { $0.setAudioEnabled(false) } }
        player.setAudioEnabled(!player.isAudioEnabled)
    }
    func savePreferences() {do{try persist();notify("设置已保存")}catch{report(error)}}
    func disconnectAll() {players.values.forEach{$0.stop()}}
    func shutdown() {guard !stopping else{return};stopping=true;ptzTasks.values.forEach{$0.cancel()};disconnectAll()}
}
