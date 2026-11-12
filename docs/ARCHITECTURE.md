# Windows 技术方案

## 结论

建议采用 **Rust 共享核心 + SwiftUI/AppKit/UIKit + WinUI 3/Windows App SDK**。Rust 负责多个平台真正应该一致的能力，Swift 和 C# 分别负责各自平台的 UI、生命周期和系统集成。

Windows 端仍建议使用 C#/.NET 10 LTS 承载 WinUI 3 应用层。WinUI 3 是 Windows App SDK 提供的原生桌面 UI 框架，适合做 Windows 专属体验；它不应该成为跨平台业务层的抽象。

## 为什么这样拆分

### UI 与平台层

WinUI 3 负责 Windows 原生桌面体验；macOS、iOS 继续分别使用 SwiftUI 与必要的 AppKit/UIKit。三端共享状态模型和业务协议，但不强行共享 View、导航、窗口和系统交互。

Windows 应用层使用 MVVM：View 只处理展示，ViewModel 负责状态和命令，平台服务负责窗口、文件、通知、媒体键、后台任务和凭据。macOS/iOS 保留各自的 Swift 视图模型适配层。

建议的项目分层：

```text
crates/
  ocplayer-core/              # 播放、媒体模型、同步规则和跨平台业务
  ocplayer-ffi/               # 稳定的 C ABI、句柄、事件和错误码
  liberika/                   # 现有 Rust 播放内核
platforms/
  windows/                    # WinUI 3、C# ViewModel、Windows 系统服务
  apple/                      # SwiftUI/AppKit/UIKit、Swift 适配层
native/
  artifacts/                  # 各平台构建产物，不提交到 Git
tests/
  ocplayer-core-tests/
  ocplayer-ffi-tests/
```

### 共享 Rust 核心

OcPlayer 已经有 Rust 编写的 `liberika`，内部使用 FFmpeg 和 libass。建议以它为起点，逐步把真正跨平台的能力收拢到 `ocplayer-core`，包括媒体播放、媒体信息、播放队列、继续观看、进度同步、字幕轨道和服务端协议模型。这样 macOS、iOS、Windows 的行为可以由同一套核心逻辑保证。

不要一次性重写所有 Swift 代码。先让现有 Apple 应用继续工作，再按模块把共享逻辑迁移到 Rust；每迁移一个模块，就让 Swift 端通过适配器调用 Rust，并保留一段时间的行为对照测试。

跨平台接口建议先定义为：

- 创建 / 销毁播放器实例
- 打开本地路径或网络 URL
- 播放、暂停、跳转、倍速和音量
- 获取媒体信息与播放时钟
- 选择音轨、字幕轨和章节
- 输出视频帧 / 绑定渲染目标
- 订阅错误、状态和播放进度事件

C ABI 只暴露 opaque handle、整数、浮点数、UTF-8 字符串、字节缓冲区和明确的错误码。所有内存释放由 Rust 提供对应函数，事件采用回调或可轮询事件队列。不要把 Rust 的 Vec、String、trait、Future 或内部结构体直接暴露给 Swift/C#。

Swift 端可以用 C header/modulemap 或 UniFFI 生成包装；Windows 端用 native DLL + P/Invoke 包一层 C# API。UniFFI 对 Swift 有成熟支持，但其 C# 支持属于第三方绑定路径，因此第一版最好让两端都围绕同一份 C ABI 工作。

Rust 的 ABI 不保证跨版本稳定，所以 FFI 层必须显式使用 `extern "C"`，并单独维护头文件、版本号和兼容性测试。这样可以把 Rust 内部重构与 Swift/C# 客户端解耦。

### 不适合放进共享 Rust 核心的部分

以下能力应该保留在平台层：

- SwiftUI、WinUI、导航、窗口和渲染控件
- AppKit/UIKit、Win32/Windows App SDK 的生命周期与系统事件
- AirPlay、Picture in Picture、媒体中心、Windows 媒体键、通知和文件选择器
- Keychain、Windows Credential Manager、DPAPI 等安全存储
- MSIX、App Store、沙盒、后台任务和平台特定权限

### 数据与服务

SQLite 只保存本地状态：服务器列表、登录会话引用、播放历史、继续观看、播放设置和缓存索引。密码与令牌使用 Windows Credential Manager / DPAPI 保护，不写入普通 JSON 或日志。

Jellyfin、Emby、Bangumi、MoviePilot 和弹幕网关分别放在独立的服务适配器中。每个适配器向应用层提供稳定接口，并在边界处完成重试、超时、取消、分页和错误映射。

### 发布与诊断

开发阶段同时保留 packaged 和 unpackaged 两种运行方式。正式发布优先 MSIX，后续如有需要再补充独立安装器。CI 至少执行还原、编译、单元测试、打包和许可证 / 第三方 notices 检查。

## 第一阶段建议

1. 先把现有 Swift 播放逻辑与 `liberika` 的边界画出来，确定哪些状态和能力必须跨平台一致。
2. 建立 `ocplayer-core` 与 `ocplayer-ffi`，先迁移媒体模型、播放状态和本地播放控制。
3. 在 macOS/iOS 保持原 UI 不变，用 Swift 适配层接入 Rust 核心。
4. 生成 WinUI 3 解决方案，用 C# P/Invoke 接入同一套 Rust 核心。
5. 再迁移 Jellyfin / Emby 协议、播放进度同步、继续观看和弹幕。
6. 最后补齐窗口体验、系统媒体控制、MoviePilot、Bangumi、自动更新和高级画质功能。
