# CamDesk 项目规则

> 这份文件是 CamDesk 仓库的最高优先级项目规则。任何在本仓库里动代码、动发布的人或 agent 都要先读它。

## 铁的规矩：任何修改都要三件事一起做完

一次改动只有**同时满足下面三条**才算完成。缺任何一条都算没做完。

### 1. 覆盖 —— 本机必须跑最新版

代码改完、构建通过之后，把新构建覆盖安装到 `/Applications/CamDesk.app`，并验证：

```bash
defaults read /Applications/CamDesk.app/Contents/Info.plist CFBundleShortVersionString
codesign -v /Applications/CamDesk.app
shasum -a 256 /Applications/CamDesk.app/Contents/MacOS/CamDesk
```

第三条的哈希必须跟 `dist/` 里刚构建产物一致。覆盖前先把旧版本备份到 `~/.dsh/backups/CamDesk-before-<version>-<时间戳>.app`。

不能出现"仓库里改了、本机还是老版本"的状态。

### 2. 登记 —— 交接文档必须更新

改完立刻更新 [`HANDOVER.md`](HANDOVER.md)：

- 在"变更记录"里追加一行，写清日期、版本、动了什么、为什么、验证方式、回滚路径。
- 改动了行为、接口、依赖、构建方式、已知限制时，同步更新对应章节。
- 版本号变了要改 `Resources/Info.plist` 的 `CFBundleShortVersionString` 和 `CFBundleVersion`，并在 `CHANGELOG.md` 加条目。

`HANDOVER.md` 是给下一个人（或下一个 agent）看的现状快照，不是历史流水账。过时的内容要直接删掉或改对，不要留着误导人。

### 3. 更新 GitHub —— 必须推上去

```bash
git add -A
git commit -m "<改了什么>"
git -c credential.helper= -c credential.helper='!gh auth git-credential' push origin main
```

注意：直接 `git push` 会挂在凭据管理器上，必须带上上面那串 `-c credential.helper` 参数。

有版本发布时，还要上传 DMG 到 Release：

```bash
gh release create v<version> dist/CamDesk-<version>-arm64.dmg \
  dist/CamDesk-<version>-arm64.dmg.sha256 \
  --title "CamDesk <version>" --notes "<说明>"
```

发版前先确认 `dist/CamDesk-<version>-arm64.dmg` 已经存在且哈希对得上。

## 收尾自检

一次改动交付前，逐条对照：

- [ ] 本机 `/Applications/CamDesk.app` 版本号 = 新版本号
- [ ] 二进制哈希 = `dist/` 构建产物哈希
- [ ] `HANDOVER.md` 变更记录已追加
- [ ] `CHANGELOG.md` 已更新（有版本变化时）
- [ ] 代码和文档已 commit
- [ ] 已 push 到 `origin/main`
- [ ] 有发版的话 DMG 已上传到 Release
- [ ] 备份路径已告知

## 构建与测试

```bash
./build.sh              # 编译 + 签名 + 打包 DMG 到 dist/
./Tests/run-tests.sh    # 跑测试
```

## 技术约束

- 最低 macOS 14.0，仅 arm64。
- 只有 Command Line Tools，没有 Xcode 项目，用 `swiftc` 直接编译。
- SwiftUI 的 `@State` 在这个 SDK 上会宏冲突，**必须用 `@CamDeskState`**（定义在 `Sources/Compatibility.swift`）。
- 一台摄像头同时只允许一个 RTSP 客户端。录像进程要独占连接。
- 没有 Apple Developer ID，只能 ad-hoc 签名，**未公证**。用户首次打开需要右键 → 打开，或 `xattr -d com.apple.quarantine /Applications/CamDesk.app`。

## 已知限制

- FFmpeg 的 RTSP 解复用器不认 `-user`/`-password`，凭据只能写在 URL 里，同一用户的 `ps` 能看到。
- 只支持 macOS，不支持 Windows。
