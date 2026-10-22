import SwiftUI
import AppKit

private let mint = Color.accentColor
private let canvas = Color(nsColor:.windowBackgroundColor)
private let panel = Color(nsColor:.controlBackgroundColor)
private let soft = Color(nsColor:.secondaryLabelColor)

struct VideoSurface: View {
    @ObservedObject var player:CameraPlayer
    var body: some View {
        GeometryReader {geometry in
            ZStack {
                Color.black
                if let image=player.image {Image(nsImage:image).resizable().scaledToFit().frame(width:geometry.size.width,height:geometry.size.height)}
                else {VStack(spacing:11){Image(systemName:"video.slash").font(.system(size:30));Text(player.status).font(.callout)}.foregroundStyle(Color.white.opacity(0.8))}
                MediaStatusOverlay(player: player, showsActions: false)
            }
        }
    }
}
struct MediaStatusOverlay: View {
    @ObservedObject var player: CameraPlayer
    var showsActions = true
    var body: some View {
        if player.isConnecting || player.isFinalizingRecording || player.errorMessage != nil || player.recordingError != nil {
            MediaStatusFeedback(player: player, showsActions: showsActions)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
        }
    }
}

struct MediaStatusFeedback: View {
    @ObservedObject var player: CameraPlayer
    var showsActions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = player.recordingError ?? player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(player.recordingError != nil ? "录像错误" : "连接错误")：\(error)")
                if showsActions {
                    if player.recordingError != nil {
                        Text("请检查保存位置后重试录像。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !player.isConnecting {
                        Button("重新连接") { player.reconnect() }
                    }
                }
            }
            if player.isConnecting {
                HStack {
                    ProgressView().controlSize(.small).accessibilityLabel("正在连接")
                    Text("连接中…")
                    if showsActions { Button("取消连接") { player.stop() } }
                }
            }
            if player.isFinalizingRecording {
                Label("录像保存中…", systemImage: "hourglass")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LibraryView:View {
    @EnvironmentObject var store:AppStore
    @CamDeskState private var filter="全部"
    var items:[LibraryItem]{store.library.filter{filter=="全部" || (filter=="录像" ? $0.isVideo:!$0.isVideo)}}
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {VStack(alignment:.leading,spacing:4){Text("录像与截图").font(.headline);Text("保存在你选择的本机文件夹").font(.callout).foregroundStyle(.secondary)};Spacer();Button("打开文件夹"){store.reveal(URL(fileURLWithPath:store.preferences.captureDirectory))};Button{store.refreshLibrary()}label:{Image(systemName:"arrow.clockwise").frame(width:28,height:28)}.accessibilityLabel("刷新录像与截图")}
            Picker("类型",selection:$filter){Text("全部").tag("全部");Text("录像").tag("录像");Text("截图").tag("截图")}.pickerStyle(.segmented).frame(width:240)
            if items.isEmpty {VStack(spacing:15){Image(systemName:"photo.on.rectangle.angled").font(.system(size:38,weight:.ultraLight)).foregroundStyle(mint);Text("这里将保存你的录像与截图");Text("在实时画面上方，点击截图或录像按钮开始。").font(.callout).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,maxHeight:.infinity)}
            else {List {ForEach(items){item in HStack(spacing:14){Image(systemName:item.isVideo ? "play.rectangle":"photo").font(.title3).foregroundStyle(.tint).frame(width:34,height:34);VStack(alignment:.leading,spacing:5){Text(item.url.lastPathComponent).font(.body).lineLimit(1);Text("\(item.created.formatted(date:.abbreviated,time:.shortened)) · \(item.sizeLabel)").font(.callout).foregroundStyle(.secondary)};Spacer();Button(item.isVideo ? "播放":"查看"){if item.isVideo{store.playback=item}else{NSWorkspace.shared.open(item.url)}};Button{store.reveal(item.url)}label:{Image(systemName:"folder")}.help("在 Finder 中显示")}.padding(12)}}}
            Spacer(minLength:0)
        }.padding(20).onAppear{store.refreshLibrary()}
    }
}
struct PreferencesView:View {
    @EnvironmentObject var store:AppStore
    var body:some View {
        Form {
            Section("视频引擎") {
                TextField("FFmpeg 路径",text:$store.preferences.ffmpegPath)
                Label(FileManager.default.isExecutableFile(atPath:store.preferences.ffmpegPath) ? "已找到视频引擎":"请填写可执行的 FFmpeg 路径",systemImage:FileManager.default.isExecutableFile(atPath:store.preferences.ffmpegPath) ? "checkmark.circle":"exclamationmark.triangle").foregroundStyle(.secondary)
            }
            Section("截图与录像") {
                Text(store.preferences.captureDirectory).textSelection(.enabled)
                Button("更改保存文件夹…"){store.chooseOutputDirectory()}
                Text("截图保存为 JPEG；录像保存为 MKV。").foregroundStyle(.secondary)
            }
            Section("配置") {
                HStack {Button("导入配置…"){store.importConfiguration()};Button("导出配置…"){store.exportConfiguration()}}
                Text("连接地址与密码保存在本机钥匙串。导出文件不包含单独保存的密码。").foregroundStyle(.secondary)
            }
            HStack {Spacer();Button("保存设置"){store.savePreferences()}.buttonStyle(.borderedProminent)}
        }.formStyle(.grouped).font(.body).padding(12)

    }
}

struct PlaybackView:View {
    let item:LibraryItem
    @StateObject private var player:CameraPlayer
    @CamDeskState private var zoom:Double=1
    @Environment(\.dismiss) var dismiss
    init(item:LibraryItem,ffmpegPath:String) {self.item=item;_player=StateObject(wrappedValue:CameraPlayer(configuration:StreamConfiguration(name:item.url.lastPathComponent,url:item.url.absoluteString,ffmpegPath:ffmpegPath)))}
    var body:some View {
        VStack(spacing:15) {
            HStack {Text(item.url.lastPathComponent).font(.headline).lineLimit(1);Spacer();Button("关闭"){dismiss()}}
            ZoomVideoSurface(player:player,zoom:$zoom).frame(minWidth:620,minHeight:350)
            HStack {Button("重新播放"){player.reconnect()};Button("停止"){player.stop()};Text(player.status).font(.system(size:11)).foregroundStyle(soft);Spacer();Button("在 Finder 中显示"){NSWorkspace.shared.activateFileViewerSelecting([item.url])}}
            AudioControls(player:player).frame(width:260)
        }.padding(24).background(canvas).onAppear{player.start()}.onDisappear{player.stop()}
    }
}
