import SwiftUI
import AppKit

struct CameraEditor:View {
    @Environment(\.dismiss) private var dismiss
    @CamDeskState var draft:CameraDraft
    let onSave:(CameraDraft)throws->Void
    @CamDeskState private var profiles:[ONVIFProfile]=[]
    @CamDeskState private var isLoading=false
    @CamDeskState private var errorMessage=""
    @CamDeskState private var showPassword=false
    @CamDeskState private var advanced=false
    @CamDeskState private var requestTask:Task<Void,Never>?
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {VStack(alignment:.leading,spacing:6){Text("摄像头设置").font(.system(size:22,weight:.medium));Text("填写视频地址即可观看；云台设置可按需展开。").font(.system(size:12)).foregroundStyle(.secondary)};Spacer();Button{dismiss()}label:{Image(systemName:"xmark").font(.system(size:12)).frame(width:26,height:26)}.buttonStyle(.plain)}.padding(25)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:19) {
                    HStack(spacing:18){field("名称",text:$draft.camera.name);field("分组",text:$draft.camera.group)}
                    Toggle("本地演示源（由 FFmpeg 生成测试画面）",isOn:$draft.camera.isDemo).font(.system(size:12))
                    if !draft.camera.isDemo {
                        field("视频流地址",placeholder:"rtsp://192.168.1.10:554/stream1",text:$draft.connection.streamURL)
                        Text("支持 RTSP / RTSPS、HTTP / HLS / MJPEG，以及 FFmpeg 支持的 RTMP / SRT。建议使用独立的摄像头观看账号。").font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(4)
                        HStack(alignment:.top,spacing:18) {
                            field("用户名",text:$draft.connection.username)
                            VStack(alignment:.leading,spacing:7){Text("密码").font(.system(size:12)).foregroundStyle(.secondary);HStack{Group{if showPassword{TextField("密码",text:$draft.connection.password)}else{SecureField("密码",text:$draft.connection.password)}}.textFieldStyle(.roundedBorder);Button{showPassword.toggle()}label:{Image(systemName:showPassword ? "eye.slash":"eye")}.buttonStyle(.borderless).frame(width:32,height:32).accessibilityLabel("显示或隐藏密码").help("显示或隐藏密码")}}
                        }
                        Toggle("RTSP 使用 TCP（更可靠；取消后使用 UDP）",isOn:$draft.camera.useTCP).font(.system(size:12))
                        Divider().padding(.vertical,2)
                        DisclosureGroup("ONVIF 与云台",isExpanded:$advanced) {
                        VStack(alignment:.leading,spacing:14) {
                        HStack {Text("ONVIF 与云台").font(.system(size:13,weight:.medium));Spacer();Text("可选").font(.system(size:12)).foregroundStyle(.secondary)}
                        field("ONVIF 设备服务地址",placeholder:"http://192.168.1.10/onvif/device_service",text:$draft.connection.onvifEndpoint)
                        HStack {Button {fetchProfiles()} label:{Label(isLoading ? "正在读取…":"读取视频配置",systemImage:"arrow.triangle.2.circlepath")}.disabled(isLoading || draft.connection.onvifEndpoint.isEmpty);if isLoading{ProgressView().controlSize(.small)};Spacer()}
                        if !profiles.isEmpty {
                            Picker("视频配置",selection:$draft.camera.profileToken) {ForEach(profiles){profile in Text(profile.name).tag(profile.id)}}
                            .onChange(of:draft.camera.profileToken){_,token in if let url=profiles.first(where:{$0.id==token})?.streamURL{draft.connection.streamURL=url.absoluteString}}
                        } else {
                            field("视频配置 Token",placeholder:"读取配置后自动填写，也可手动输入",text:$draft.camera.profileToken)
                        }
                        Text("ONVIF 的账号权限、服务端口可能与网页管理不同。摄像头需要已启用 ONVIF，云台功能还需设备支持 PTZ。").font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(4)
                        }
                        }
                    }
                    Divider()
                    HStack {Toggle("启动时自动连接",isOn:$draft.camera.autoConnect);Spacer();Toggle("收藏",isOn:$draft.camera.isFavorite)}.font(.system(size:12))
                    Label("连接地址与密码仅保存在本机钥匙串。",systemImage:"lock.shield").font(.system(size:12)).foregroundStyle(.secondary)
                    if !errorMessage.isEmpty {Text(errorMessage).font(.system(size:12)).foregroundStyle(.orange).textSelection(.enabled).padding(11).frame(maxWidth:.infinity,alignment:.leading).background(Color.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:8))}
                }.padding(25)
            }
            Divider()
            HStack {Button("取消"){dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button("保存并应用"){do{try onSave(draft);dismiss()}catch{errorMessage=error.localizedDescription}}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(draft.camera.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}.padding(20)
        }.frame(width:620,height:690).background(Color(nsColor:.windowBackgroundColor)).onAppear{advanced = !draft.connection.onvifEndpoint.isEmpty}.onDisappear{requestTask?.cancel()}
    }
    private func field(_ label:String,placeholder:String="",text:Binding<String>)->some View {
        VStack(alignment:.leading,spacing:7){Text(label).font(.system(size:12)).foregroundStyle(.secondary);TextField(placeholder,text:text).textFieldStyle(.roundedBorder).font(.system(size:12))}
    }
    private func fetchProfiles() {
        guard let endpoint=URL(string:draft.connection.onvifEndpoint),["http","https"].contains(endpoint.scheme?.lowercased() ?? ""),endpoint.host != nil else {errorMessage="请输入有效的 ONVIF 服务地址。";return}
        isLoading=true;errorMessage=""
        let credentials=ONVIFCredentials(username:draft.connection.username,password:draft.connection.password)
        requestTask=Task {
            do {
                let client=ONVIFClient(endpoint:endpoint,credentials:credentials)
                let result=try await client.profiles()
                guard !Task.isCancelled else{return}
                profiles=result
                if let selected=result.first(where:{$0.id==draft.camera.profileToken}) ?? result.first {
                    draft.camera.profileToken=selected.id
                    if let url=selected.streamURL {draft.connection.streamURL=url.absoluteString}
                }
                if result.isEmpty {errorMessage="设备没有返回视频配置，请检查 ONVIF 权限。"}
            }catch{if !Task.isCancelled{errorMessage=error.localizedDescription}}
            isLoading=false
        }
    }
}

struct DiscoveryView:View {
    @EnvironmentObject var store:AppStore
    @Environment(\.dismiss) private var dismiss
    @CamDeskState private var devices:[ONVIFDevice]=[]
    @CamDeskState private var searching=false
    @CamDeskState private var message=""
    @CamDeskState private var requestTask:Task<Void,Never>?
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {VStack(alignment:.leading,spacing:7){Text("发现附近的摄像头").font(.system(size:22,weight:.medium));Text("使用 ONVIF WS-Discovery 查找同一局域网中的设备。").font(.system(size:12)).foregroundStyle(.secondary)};Spacer();Button("关闭"){dismiss()}}
            HStack {Button {scan()}label:{Label(searching ? "正在发现设备…":"重新发现",systemImage:"dot.radiowaves.left.and.right")}.buttonStyle(.borderedProminent).disabled(searching);if searching{ProgressView().controlSize(.small)};Spacer();Text("239.255.255.250 · ONVIF").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)}
            if devices.isEmpty {
                VStack(spacing:14){Image(systemName:"network").font(.system(size:36,weight:.ultraLight)).foregroundStyle(.secondary);Text(searching ? "正在等待设备响应":"尚未发现 ONVIF 设备").font(.system(size:15));Text("请确认摄像头和 Mac 处于同一网络，\n设备已启用 ONVIF，且已允许 CamDesk 访问本地网络。").font(.system(size:12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6)}.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView {VStack(spacing:9){ForEach(devices){device in HStack(spacing:13){Image(systemName:"web.camera").font(.system(size:25)).foregroundStyle(.mint);VStack(alignment:.leading,spacing:5){Text(device.name).font(.system(size:12,weight:.medium));Text(device.endpoint.absoluteString).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(2)};Spacer();Button("添加"){add(device)}}.padding(15).background(Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:10))}}}
            }
            if !message.isEmpty {Text(message).font(.system(size:12)).foregroundStyle(.orange)}
            Text("多播发现仅限本地网络；手动填写服务地址也可接入不响应发现的设备。不会自动登录或修改设备配置。").font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(26).frame(width:660,height:530).background(Color(nsColor:.windowBackgroundColor)).onAppear{scan()}.onDisappear{requestTask?.cancel()}
    }
    private func scan() {
        guard !searching else{return};searching=true;message="";devices=[]
        requestTask=Task {
            do {let found=try await ONVIFDiscovery().discover(timeout:3);if !Task.isCancelled{devices=found}}
            catch{if !Task.isCancelled{message=error.localizedDescription}}
            searching=false
        }
    }
    private func add(_ device:ONVIFDevice) {
        let draft=CameraDraft(camera:CameraRecord(name:device.name,hostHint:device.endpoint.host ?? ""),connection:ConnectionSecrets(onvifEndpoint:device.endpoint.absoluteString))
        dismiss()
        Task { @MainActor in try? await Task.sleep(nanoseconds:300_000_000);store.editDraft=draft }
    }
}
