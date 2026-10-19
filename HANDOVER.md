# CamDesk 交接文档

> 现状快照。看完这份就能接手，不用翻历史。
>
> 最后更新：2026-10-19 / v1.0.1

## 项目是什么

CamDesk 是一个 macOS 原生摄像头监控应用。接 RTSP / RTSPS / HTTP / HLS 流和 ONVIF 摄像头，本地多路预览、PTZ 云台控制、录像到本地磁盘。

- 开源仓库：https://github.com/622cc/CamDesk
- 许可证：MIT
- 作者：622cc
- 形态：单窗口桌面应用，纯 SwiftUI + AppKit，无 Electron、无 WebView

## 当前状态

| 项 | 值 |
| --- | --- |
| 版本 | 1.0.1（构建号 2） |
| 本机安装 | `/Applications/CamDesk.app`，已覆盖为 1.0.1 |
| Bundle ID | `com.github.622cc.camdesk` |
| 最低系统 | macOS 14.0 Sonoma |
| 架构 | arm64（Apple Silicon 专用） |
| 签名 | ad-hoc（无 Developer ID，**未公证**） |
| 最新 Release | https://github.com/622cc/CamDesk/releases/tag/v1.0.1 |
| DMG | `dist/CamDesk-1.0.1-arm64.dmg`（593282 字节） |
| DMG SHA-256 | `88e9176fd7884a3475e3b5357971aab60c1ba82976a2cdf350ea2ad047df7e31` |

## 目录结构

```
Sources/
  CamDeskApp.swift        应用入口，菜单命令，窗口尺寸约束
  ContentView.swift       主视图骨架
  NativeWorkspace.swift   主工作区：侧栏 + 播放区 + 检查器，含窄窗口分支
  MediaEngine.swift       FFmpeg 子进程封装：预览、音频、录像
  ONVIF.swift             ONVIF 发现、WS-Security、PTZ
  Models.swift            Preferences / Camera / AppStore（状态与持久化）
  CameraEditor.swift      添加与编辑摄像头表单
  FFmpegLocator.swift     FFmpeg 路径发现与可执行性校验
  VideoZoom.swift         画面缩放与适应模式
  Compatibility.swift     兼容层：CamDeskState、旧包标识迁移
Resources/
  Info.plist
Tests/
  run-tests.sh            测试入口，编译后跑断言
  *.swift                 各模块断言
build.sh                  编译 → 签名 → 打包 DMG → 写 .sha256
CHANGELOG.md              面向用户的版本变更
HANDOVER.md               本文件
AGENTS.md                 项目规则（改动的三条硬性要求）
```

`build/`、`.build/`、`dist/` 都是构建产物，不进版本库（`.sha256` 除外）。

## 怎么构建

只依赖 Command Line Tools，不需要 Xcode。

```bash
./build.sh              # 产物落在 dist/
./Tests/run-tests.sh    # 跑测试
```

`build.sh` 用 `swiftc` 直接编译，然后 `codesign --force --deep --sign "${CODESIGN_IDENTITY:--}"` 签名，最后用 `hdiutil` 打 DMG（内含 `CamDesk.app` 和一个指向 `/Applications` 的符号链接）。

## 怎么发布

```bash
./build.sh
shasum -a 256 dist/CamDesk-<version>-arm64.dmg      # 核对
gh release create v<version> \
  dist/CamDesk-<version>-arm64.dmg \
  dist/CamDesk-<version>-arm64.dmg.sha256 \
  --title "CamDesk <version>" --notes "<说明>"
```

推送提交时必须这样写，否则会卡在凭据管理器上：

```bash
git -c credential.helper= -c credential.helper='!gh auth git-credential' push origin main
```

## 关键设计决定

**为什么用 FFmpeg 子进程而不是 AVFoundation。** AVFoundation 不直接支持 RTSP。所有网络流交给 ffmpeg，读它的 stdout，用 `h264`/`hevc` 裸流喂给 AVSampleBufferDisplayLayer。

**为什么录像要独占连接。** 绝大多数 IPC 摄像头同时只允许一个 RTSP 客户端。如果预览已经占着连接，第二个录像进程会直接被拒（ffmpeg 退出码 183）。解决办法：开录时停掉预览和音频，让录像进程独占连接，同时把它解出的画面送回预览区。实现见 `MediaEngine.startRecording(to:)`。

**为什么用 `@CamDeskState` 而不是 `@State`。** 当前 SDK（27）的 SwiftUI `@State` 宏在 Command Line Tools 环境下找不到 `SwiftUIMacros.StateMacro`，编译直接失败。兼容层用 `typealias CamDeskState<Value> = SwiftUI.State<Value>` 绕过宏展开。**新代码一律用 `@CamDeskState`。**

**为什么打包标识换过。** 早期版本用 `local.camdesk.mac`，开源后改成 `com.github.622cc.camdesk`。`Compatibility.swift` 里做了自动迁移，老用户配置不会丢。

**窄窗口怎么处理。** `NativeWorkspace` 用 `GeometryReader` 判断宽度，小于 900pt 视为 compact：检查器从右侧栏改成工具栏弹出的 popover（300×500），播放区跳过 `HSplitView` 直接铺满。窗口最小尺寸 560×400。

## 已知限制

**FFmpeg 凭据只能在 URL 里。** ffmpeg 的 RTSP 解复用器只认 `user_agent` 和 `ca_file`，没有 `-user`/`-password`。试过 `pipe:0`、`/dev/stdin`、`-headers` 带 Authorization、`argumentsAreHidden`、`setproctitle`，全部无效。结果就是：配置里写了凭据的摄像头，同一用户执行 `ps` 能看到明文 URL。这是 ffmpeg 的固有限制，不是实现缺陷。

**只有 arm64。** Intel Mac 跑不了。

**未公证。** 没有 Apple Developer ID（每年 99 美元）。用户首次打开会被 Gatekeeper 拦住，需要右键 → 打开，或：

```bash
xattr -d com.apple.quarantine /Applications/CamDesk.app
```

**首启引导未做视觉验证。** 缺少 FFmpeg 时的 `FFmpegSetupView` 能编译，但没在"找不到 ffmpeg"的真实状态下看过界面。测试机总能找到 `/opt/homebrew/bin/ffmpeg`，试过改配置和隔离 `HOME` 都失败（`NSHomeDirectory` 不理会 shell 的 `HOME`）。

## 变更记录

| 日期 | 版本 | 改动 | 验证 | 回滚 |
| --- | --- | --- | --- | --- |
| 2026-10-19 | — | 新增 `AGENTS.md` 和 `HANDOVER.md`，把"覆盖本机 + 登记交接 + 推送 GitHub"固化为项目规则 | 文件已落到仓库并推送 | `rm AGENTS.md HANDOVER.md` |
| 2026-10-19 | 1.0.1 | FFmpeg 自动发现（`FFmpegLocator`）、缺少 FFmpeg 时首启引导、窄窗口布局、单会话录像修复 | 本机 1.0.1 覆盖安装，二进制哈希与构建产物一致；真实摄像头 TP-IPC 录出 HEVC 2560×1440 | `~/.dsh/backups/CamDesk-before-1.0.1-20261019-194209.app` |
| 2026-10-19 | 1.0.0 | 首次公开发布，含 DMG 打包脚本 | Release 已上传 | — |
