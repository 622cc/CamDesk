// HIG-aligned layout for CamDesk: NavigationSplitView + List + HSplitView inspector.
// Design-review pass lives in UI-REVIEW.md; this file is the implementation.
import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @CamDeskState private var booted = false
    @CamDeskState private var columnVisibility: NavigationSplitViewVisibility = .all
    @CamDeskState private var compactInspectorPresented = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar().environmentObject(store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 320)
        } detail: {
            GeometryReader { geometry in
                let compact = geometry.size.width < 900
                Group {
                    if store.section == "library" { LibraryView() }
                    else { ViewerScreen(compact: compact) }
                }
                .navigationTitle(store.section == "library" ? "录像与截图" : (store.selected?.name ?? "摄像头"))
                .navigationSubtitle(subtitle)
                .toolbar { toolbarContent(compact: compact) }
                .onChange(of: compact) { _, isCompact in
                    if !isCompact { compactInspectorPresented = false }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if !booted { booted = true; store.startSavedCameras(); store.refreshLibrary() } }
        .sheet(item: $store.editDraft) { CameraEditor(draft: $0) { try store.save($0) } }
        .sheet(isPresented: $store.discoverVisible) { DiscoveryView() }
        .sheet(item: $store.playback) { PlaybackView(item: $0, ffmpegPath: store.preferences.ffmpegPath) }
        .alert(item: $store.issue) { Alert(title: Text("操作未完成"), message: Text($0.message), dismissButton: .default(Text("好"))) }
        .onReceive(NotificationCenter.default.publisher(for: .camDeskToggleSidebar)) { _ in
            columnVisibility = columnVisibility == .all ? .detailOnly : .all
        }
        .onReceive(NotificationCenter.default.publisher(for: .camDeskFullscreen)) { _ in NSApp.keyWindow?.toggleFullScreen(nil) }
    }

    private var subtitle: String {
        guard let camera = store.selected, store.section != "library" else { return "\(store.cameras.count) 台摄像头" }
        if let player = store.players[camera.id] {
            if player.isRecording { return "录像中" }
            return player.isConnected ? "在线" : player.status
        }
        return camera.hostHint
    }

    @ToolbarContentBuilder private func toolbarContent(compact: Bool) -> some ToolbarContent {
        ToolbarItemGroup {
            if store.section != "library" {
                Picker("观看方式", selection: $store.focusedView) {
                    Image(systemName: "rectangle").tag(true).help("单画面")
                    Image(systemName: "square.grid.2x2").tag(false).help("多画面")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 78)
                .help("单画面或多画面观看")
                Button {
                    if compact { compactInspectorPresented.toggle() }
                    else { store.controlsVisible.toggle() }
                } label: {
                    Label("检查器", systemImage: "sidebar.trailing")
                }
                .help(compact
                      ? (compactInspectorPresented ? "隐藏检查器" : "显示检查器")
                      : (store.controlsVisible ? "隐藏检查器" : "显示检查器"))
                .disabled(store.selected == nil)
                .popover(isPresented: $compactInspectorPresented, arrowEdge: .bottom) {
                    if let camera = store.selected {
                        Inspector(camera: camera)
                            .environmentObject(store)
                            .frame(width: 300, height: 500)
                    }
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("手动添加摄像头…") { store.editDraft = CameraDraft() }
                Button("发现局域网 ONVIF 设备…") { store.discoverVisible = true }
                Divider()
                Button("添加本地演示源") { store.addDemo() }
            } label: { Label("添加摄像头", systemImage: "plus") }
                .help("手动添加摄像头或发现局域网设备")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        List(selection: selection) {
            Section("资料库") {
                Label("所有摄像头", systemImage: "square.grid.2x2").tag(SidebarItem.all)
                Label("收藏", systemImage: "star").tag(SidebarItem.favorites)
                Label("录像与截图", systemImage: "photo.on.rectangle").tag(SidebarItem.library)
            }
            ForEach(store.groups, id: \.self) { group in
                let cameras = store.cameras.filter { $0.group == group }
                Section(group) {
                    ForEach(cameras) { camera in
                        SidebarCameraRow(camera: camera, player: store.players[camera.id])
                            .tag(SidebarItem.camera(camera.id))
                            .contextMenu { cameraMenu(camera) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("摄像头")
        .searchable(text: $store.search, placement: .sidebar, prompt: "搜索")
    }
    enum SidebarItem: Hashable { case all, favorites, library, camera(UUID) }
    private var selection: Binding<SidebarItem?> {
        Binding(get: {
            if store.section == "library" { return .library }
            if store.groupFilter == "收藏" { return .favorites }
            if let id = store.selectedID, store.focusedView { return .camera(id) }
            return .all
        }, set: { value in
            guard let value else { return }
            switch value {
            case .library: store.section = "library"; store.refreshLibrary()
            case .favorites: store.groupFilter = "收藏"; store.section = "live"
            case .all: store.groupFilter = "全部摄像头"; store.section = "live"; store.focusedView = false
            case .camera(let id): store.selectedID = id; store.section = "live"; store.focusedView = true
            }
        })
    }
    @ViewBuilder private func cameraMenu(_ camera: CameraRecord) -> some View {
        Button("观看") { store.selectedID = camera.id; store.focusedView = true; store.section = "live" }
        Button("重新连接") { store.reconnect(camera) }
        Button("编辑摄像头…") { store.edit(camera) }
        Button(camera.isFavorite ? "取消收藏" : "收藏") { store.toggleFavorite(camera) }
        Divider()
        Button("删除摄像头…", role: .destructive) { store.remove(camera) }
    }
}

struct SidebarCameraRow: View {
    let camera: CameraRecord
    let player: CameraPlayer?
    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(camera.name).lineLimit(1)
                if camera.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("已收藏") }
                Spacer(minLength: 0)
                if player?.isRecording == true {
                    Image(systemName: "record.circle.fill").font(.caption2).foregroundStyle(.red).accessibilityLabel("录像中")
                } else if player?.isConnected == true {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green).accessibilityLabel("在线")
                }
            }
        } icon: {
            Image(systemName: camera.isDemo ? "play.rectangle" : "video")
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Viewer

struct ViewerScreen: View {
    @EnvironmentObject var store: AppStore
    let compact: Bool
    var body: some View {
        if !FFmpegLocator.isExecutable(store.preferences.ffmpegPath) {
            FFmpegSetupView()
        } else if store.cameras.isEmpty {
            ContentUnavailableView {
                Label("还没有摄像头", systemImage: "video.badge.plus")
            } description: {
                Text("添加一台摄像头开始观看，或先体验本地演示画面。")
            } actions: {
                Button("添加摄像头…") { store.editDraft = CameraDraft() }.buttonStyle(.borderedProminent)
                Button("发现 ONVIF 设备…") { store.discoverVisible = true }
                Button("添加本地演示源") { store.addDemo() }
            }
        } else if store.focusedView, let camera = store.selected, let player = store.players[camera.id] {
            if compact {
                livePane(camera: camera, player: player)
            } else {
                HSplitView {
                    livePane(camera: camera, player: player).frame(minWidth: 420)
                    if store.controlsVisible {
                        Inspector(camera: camera)
                            .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)
                    }
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16)], spacing: 16) {
                    ForEach(store.visibleCameras) { camera in
                        if let player = store.players[camera.id] { CameraTile(camera: camera, player: player) }
                    }
                }
                .padding(16)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private func livePane(camera: CameraRecord, player: CameraPlayer) -> some View {
        VStack(spacing: 0) {
            SelectedCameraActions(camera: camera, player: player)
            Divider()
            ZoomVideoSurface(player: player, zoom: $store.viewZoom)
        }
    }
}

struct SelectedCameraActions: View {
    @EnvironmentObject var store: AppStore
    let camera: CameraRecord
    @ObservedObject var player: CameraPlayer
    var body: some View {
        HStack(spacing: 8) {
            Button { player.isConnected ? player.stop() : store.reconnect(camera) } label: {
                Label(player.isConnected ? "断开" : "连接", systemImage: player.isConnected ? "pause.fill" : "play.fill")
            }
            Button { store.snapshot(camera) } label: { Label("截图", systemImage: "camera") }
                .disabled(player.image == nil).help("保存当前画面（⇧⌘S）")
            Button { store.toggleRecording(camera) } label: {
                Label(player.isRecording ? "停止" : "录像", systemImage: player.isRecording ? "stop.fill" : "record.circle")
            }
            .tint(player.isRecording ? .red : nil)
            .disabled(!player.isConnected && !player.isRecording).help("开始或停止录像（⇧⌘R）")
            Button { store.toggleAudio(player) } label: {
                Label(player.isAudioEnabled ? "静音" : "监听", systemImage: player.isAudioEnabled ? "speaker.wave.2" : "speaker.slash")
            }
            .disabled(!player.isConnected)
            Spacer(minLength: 0)
            if !store.toast.isEmpty { Text(store.toast).font(.callout).foregroundStyle(.secondary) }
            Menu {
                Button("重新连接") { store.reconnect(camera) }
                Button("编辑摄像头…") { store.edit(camera) }
                Button(camera.isFavorite ? "取消收藏" : "收藏") { store.toggleFavorite(camera) }
                Divider()
                Button("打开录像文件夹") { store.reveal(URL(fileURLWithPath: store.preferences.captureDirectory)) }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct Inspector: View {
    @EnvironmentObject var store: AppStore
    let camera: CameraRecord
    var body: some View {
        Form {
            if let player = store.players[camera.id] {
                Section("画面") {
                    LabeledContent("缩放") {
                        HStack(spacing: 6) {
                            Button { store.viewZoom = VideoZoom.stepped(store.viewZoom, up: false) } label: { Image(systemName: "minus.magnifyingglass") }
                                .disabled(store.viewZoom <= 1).accessibilityLabel("缩小画面")
                            Text(String(format: "%.2f×", store.viewZoom)).monospacedDigit().frame(minWidth: 46)
                            Button { store.viewZoom = VideoZoom.stepped(store.viewZoom, up: true) } label: { Image(systemName: "plus.magnifyingglass") }
                                .disabled(store.viewZoom >= 8).accessibilityLabel("放大画面")
                        }
                    }
                    Button("还原为完整画面") { store.viewZoom = 1 }.disabled(store.viewZoom == 1)
                    Text("在画面上用滚轮或捏合缩放，拖动查看，双击还原。录制与截图始终使用原始画面。")
                        .font(.caption).foregroundStyle(.secondary)
                    AudioControls(player: player)
                }
            }
            Section("云台") {
                PTZControls(camera: camera)
            }
            Section("预置位") {
                PresetControls(camera: camera)
            }
            Section {
                Button("编辑摄像头…") { store.edit(camera) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct PTZControls: View {
    @EnvironmentObject var store: AppStore
    let camera: CameraRecord
    private var configured: Bool { !camera.isDemo && !camera.profileToken.isEmpty }
    var body: some View {
        if !configured {
            Label(camera.isDemo ? "演示源没有机械云台" : "尚未设置 ONVIF 连接", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            if !camera.isDemo { Button("设置云台…") { store.edit(camera) } }
        } else {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow { Color.clear.frame(width: 36, height: 26); padButton("向上", "chevron.up") { store.ptz(tilt: 1) }; Color.clear.frame(width: 36, height: 26) }
                GridRow { padButton("向左", "chevron.left") { store.ptz(pan: -1) }; padButton("停止云台", "stop.fill", action: store.stopPTZ); padButton("向右", "chevron.right") { store.ptz(pan: 1) } }
                GridRow { Color.clear.frame(width: 36, height: 26); padButton("向下", "chevron.down") { store.ptz(tilt: -1) }; Color.clear.frame(width: 36, height: 26) }
            }
            HStack {
                Button("回到原位") { store.homePTZ() }
                Spacer()
                LabeledContent("速度") {
                    Slider(value: $store.ptzSpeed, in: 0.1...1).frame(width: 90).accessibilityLabel("云台移动速度")
                }
            }
            DisclosureGroup("镜头变焦（设备支持时）") {
                HStack {
                    Button("拉远") { store.ptz(zoom: -1) }
                    Button("拉近") { store.ptz(zoom: 1) }
                }
                Text("仅对具备电动变焦镜头的设备有效，与上方的画面缩放不同。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func padButton(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 36, height: 26) }
            .accessibilityLabel(name).help(name)
    }
}

struct PresetControls: View {
    @EnvironmentObject var store: AppStore
    let camera: CameraRecord
    private var configured: Bool { !camera.isDemo && !camera.profileToken.isEmpty }
    var body: some View {
        if store.presets.isEmpty {
            Text(configured ? "读取设备保存的位置后，可一键跳转。" : "设置 ONVIF 后可读取预置位。")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(store.presets) { preset in
            Button(preset.name) { store.gotoPreset(preset) }
        }
        Button("读取预置位") { store.fetchPresets() }.disabled(!configured)
    }
}

struct CameraTile: View {
    @EnvironmentObject var store: AppStore
    let camera: CameraRecord
    @ObservedObject var player: CameraPlayer
    var body: some View {
        VStack(spacing: 0) {
            Button { store.selectedID = camera.id; store.focusedView = true } label: {
                VideoSurface(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        if player.isRecording {
                            Label("录像", systemImage: "record.circle.fill").font(.caption2).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.55), in: Capsule()).padding(8)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("观看 \(camera.name)")
            HStack {
                Text(camera.name).font(.callout).lineLimit(1)
                Spacer()
                Button { store.snapshot(camera) } label: { Image(systemName: "camera") }
                    .buttonStyle(.borderless).disabled(player.image == nil).help("保存截图")
                    .accessibilityLabel("截图 \(camera.name)")
                Button { store.toggleRecording(camera) } label: {
                    Image(systemName: player.isRecording ? "stop.fill" : "record.circle")
                        .foregroundStyle(player.isRecording ? Color.red : Color.primary)
                }
                .buttonStyle(.borderless).disabled(!player.isConnected && !player.isRecording).help("开始或停止录像")
                .accessibilityLabel("\(player.isRecording ? "停止录像" : "开始录像") \(camera.name)")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(store.selectedID == camera.id ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: store.selectedID == camera.id ? 2 : 1)
        }
    }
}

struct AudioControls: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var player: CameraPlayer
    var body: some View {
        Toggle("监听音频", isOn: Binding(get: { player.isAudioEnabled }, set: { _ in store.toggleAudio(player) }))
        LabeledContent("音量") {
            Slider(value: $player.volume, in: 0...1).frame(width: 120).accessibilityLabel("监听音量").disabled(!player.isAudioEnabled)
        }
    }
}

// First-run guidance: a missing FFmpeg means nothing can play, so say so plainly
// instead of showing a black frame. layout.md › Best practices.
struct FFmpegSetupView: View {
    @EnvironmentObject var store: AppStore
    @CamDeskState private var draftPath = FFmpegLocator.discover()
    @CamDeskState private var detected: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("需要 FFmpeg 才能播放画面")
                .font(.title3.weight(.semibold))
            Text("CamDesk 通过本机的 FFmpeg 解码视频。系统里没有找到可用的 FFmpeg，装好之后再回来。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("终端安装（任选一种）").font(.callout.weight(.medium))
                Text("brew install ffmpeg").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Text("或从 ffmpeg.org 下载静态构建，解压后把路径填到下面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                TextField("FFmpeg 可执行文件路径", text: $draftPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                Button("浏览…") { chooseBinary() }
                Button("检查") { verify() }
            }
            if let detected {
                Label(detected, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .onAppear { verify(silent: true) }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 ffmpeg 可执行文件"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url { draftPath = url.path; verify() }
    }

    private func verify(silent: Bool = false) {
        guard FFmpegLocator.isExecutable(draftPath) else {
            if !silent { store.issue = AppIssue(message: "这个路径下没有可执行的 FFmpeg。") }
            return
        }
        detected = FFmpegLocator.version(of: draftPath) ?? "已找到 FFmpeg"
        store.preferences.ffmpegPath = draftPath
        store.savePreferences()
    }
}

extension Notification.Name {
    static let camDeskToggleSidebar = Notification.Name("CamDesk.toggleSidebar")
    static let camDeskFullscreen = Notification.Name("CamDesk.fullscreen")
}
