# Changelog

## 1.0.1

- FFmpeg 路径不再写死 Homebrew 目录，改为从 `PATH` 和常见安装位置自动探测，Intel Mac 与 MacPorts 都适用
- 找不到 FFmpeg 时显示安装引导：说明原因、给出 `brew install ffmpeg`、支持浏览选择路径并当场校验版本
- README 补充 DMG 产物说明、Gatekeeper 首次放行方法，以及 FFmpeg 凭据只能放在流地址中的限制说明
- 新增 `FFmpegGateTests` 覆盖路径探测、缺失路径与版本读取

## 1.0.0

- 首个公开版本：RTSP/ONVIF 接入、云台与预置位、原始码流录像、截图与本地回放
- 单连接摄像头录制时独占会话，停止后预览自动恢复
- 窄窗口下自动收起检查器，改从工具栏弹出
- 提供 arm64 DMG 与 SHA-256 校验文件
