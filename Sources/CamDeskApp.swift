import SwiftUI
import AppKit

@main struct CamDeskApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(CamDeskDelegate.self) var delegate
    @CamDeskState private var showsReleaseNotes = false
    var body: some Scene {
        WindowGroup("摄像头") {
            ContentView().environmentObject(store).frame(minWidth:560,minHeight:400)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width:1280,height:800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("更新日志") { showsReleaseNotes = true }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
            CommandGroup(replacing:.newItem) {
                Button("添加摄像头") { store.editDraft=CameraDraft() }.keyboardShortcut("n")
                Button("发现 ONVIF 设备") { store.discoverVisible=true }.keyboardShortcut("d",modifiers:[.command,.shift])
                Divider()
                Button("导入配置…") { store.importConfiguration() }
                Button("导出配置…") { store.exportConfiguration() }
            }
            CommandMenu("摄像头") {
                Button("连接所选摄像头") {if let c=store.selected {store.reconnect(c)}}.disabled(store.selected==nil)
                Button("断开所选摄像头") {if let id=store.selectedID {store.players[id]?.stop()}}.disabled(store.selected==nil)
                Button("编辑摄像头…") {if let c=store.selected {store.edit(c)}}.keyboardShortcut("e").disabled(store.selected==nil)
                Divider()
                Button("连接全部") { store.startSavedCameras() }
                Button("断开全部") { store.disconnectAll() }
                Divider()
                Button("保存截图") { if let camera=store.selected {store.snapshot(camera)} }.keyboardShortcut("s",modifiers:[.command,.shift]).disabled(store.selected==nil)
                if let camera = store.selected, let player = store.players[camera.id] {
                    RecordingCommand(camera: camera, player: player).environmentObject(store)
                } else {
                    Button("开始／停止录像") {}.keyboardShortcut("r",modifiers:[.command,.shift]).disabled(true)
                }
                Button("监听／静音") {if let id=store.selectedID,let p=store.players[id]{store.toggleAudio(p)}}.disabled(store.selected==nil)
                Button("打开录像文件夹") {store.reveal(URL(fileURLWithPath:store.preferences.captureDirectory))}
                Divider()
                Button("添加本地演示源") {store.addDemo()}
            }
            CommandGroup(after:.sidebar) {
                Button("显示／隐藏侧栏") {NotificationCenter.default.post(name:.camDeskToggleSidebar,object:nil)}.keyboardShortcut("s",modifiers:[.command,.control])
                Button("单画面观看") {store.section="live";store.focusedView=true}.keyboardShortcut("1")
                Button("多画面观看") {store.section="live";store.focusedView=false}.keyboardShortcut("2")
                Button("显示／隐藏检查器") {NotificationCenter.default.post(name:.camDeskToggleInspector,object:nil)}.keyboardShortcut("i",modifiers:[.command,.option]).disabled(store.selected==nil || store.section=="library")
                Button("放大画面") {store.viewZoom=VideoZoom.stepped(store.viewZoom,up:true)}.keyboardShortcut("+").disabled(store.selected==nil)
                Button("缩小画面") {store.viewZoom=VideoZoom.stepped(store.viewZoom,up:false)}.keyboardShortcut("-").disabled(store.selected==nil)
                Button("还原画面") {store.viewZoom=1}.keyboardShortcut("0").disabled(store.selected==nil)
                Button("进入／退出全屏") {NotificationCenter.default.post(name:.camDeskFullscreen,object:nil)}.keyboardShortcut("f",modifiers:[.command,.control])
            }
        }
        Settings {PreferencesView().environmentObject(store).frame(width:660,height:600)}
        Window("更新日志", id: "release-notes") {
            ReleaseNotesView().frame(minWidth: 480, minHeight: 360)
        }
        .defaultSize(width: 620, height: 560)
        .onChange(of: showsReleaseNotes) { _, open in
            if open { openReleaseNotes(); showsReleaseNotes = false }
        }
    }
    @Environment(\.openWindow) private var openWindow
    private func openReleaseNotes() { openWindow(id: "release-notes"); NSApp.activate(ignoringOtherApps: true) }
}
private struct RecordingCommand: View {
    @EnvironmentObject var store: AppStore
    let camera: CameraRecord
    @ObservedObject var player: CameraPlayer
    var body: some View {
        Button(player.isFinalizingRecording ? "录像保存中…" : (player.isRecording ? "停止录像" : "开始录像")) {
            store.toggleRecording(camera)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(player.isFinalizingRecording || (!player.isConnected && !player.isRecording))
    }
}

final class CamDeskDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationDidFinishLaunching(_ notification:Notification) { NSApp.setActivationPolicy(.regular);NSApp.activate(ignoringOtherApps:true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        store?.shutdown()
        Task { @MainActor in try? await Task.sleep(nanoseconds:1_200_000_000);sender.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
}
