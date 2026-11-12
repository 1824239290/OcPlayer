# Windows 技术方案

## 结论

建议采用 **WinUI 3 + Windows App SDK + C#/.NET 10 LTS**。WinUI 3 负责桌面 UI，C# 负责应用编排和服务层，Rust 播放内核保持独立，通过一层很薄的 native bridge 暴露播放所需的能力。

## 为什么这样拆分

### UI 与应用层

WinUI 3 适合 Windows 原生桌面体验，XAML 对自适应布局、键盘操作、无障碍和 Fluent 控件支持完整。应用层使用 MVVM：View 只处理展示，ViewModel 负责状态和命令，领域服务负责登录、媒体库、播放队列、进度同步和弹幕。

建议的项目分层：

```text
src/
  OcPlayer.Windows/           # WinUI 3 应用、导航、窗口和资源
  OcPlayer.Application/       # 用例、ViewModel、应用服务接口
  OcPlayer.Domain/            # 媒体、服务器、播放状态等纯模型
  OcPlayer.Infrastructure/    # Jellyfin/Emby、SQLite、日志、文件系统
  OcPlayer.Native/            # C# 对 Rust 播放内核的 P/Invoke 封装
native/
  liberika/                   # 本地构建或下载，不直接提交二进制产物
tests/
  OcPlayer.Domain.Tests/
  OcPlayer.Application.Tests/
```

### 播放内核

OcPlayer 已经有 Rust 编写的 `liberika`，内部使用 FFmpeg 和 libass。Windows 端优先复用它，可以保持音视频解码、字幕和播放行为的一致性。建议先定义一组与平台无关的接口：

- 创建 / 销毁播放器实例
- 打开本地路径或网络 URL
- 播放、暂停、跳转、倍速和音量
- 获取媒体信息与播放时钟
- 选择音轨、字幕轨和章节
- 输出视频帧 / 绑定渲染目标
- 订阅错误、状态和播放进度事件

C ABI 只暴露句柄、整数、浮点数和 UTF-8 字符串，所有内存释放由 Rust 提供对应函数。这样可以避免 C# 直接理解 Rust 的复杂类型，也便于以后替换播放后端。

如果 `liberika` 的 Windows 渲染桥接在早期阻塞开发，再临时接入 libmpv 完成播放器壳层；不要一开始同时维护两套完整播放实现。

### 数据与服务

SQLite 只保存本地状态：服务器列表、登录会话引用、播放历史、继续观看、播放设置和缓存索引。密码与令牌使用 Windows Credential Manager / DPAPI 保护，不写入普通 JSON 或日志。

Jellyfin、Emby、Bangumi、MoviePilot 和弹幕网关分别放在独立的服务适配器中。每个适配器向应用层提供稳定接口，并在边界处完成重试、超时、取消、分页和错误映射。

### 发布与诊断

开发阶段同时保留 packaged 和 unpackaged 两种运行方式。正式发布优先 MSIX，后续如有需要再补充独立安装器。CI 至少执行还原、编译、单元测试、打包和许可证 / 第三方 notices 检查。

## 第一阶段建议

1. 生成 WinUI 3 解决方案和上述项目结构。
2. 先完成本地文件播放、播放控制、进度条、音轨 / 字幕选择。
3. 接入 Jellyfin / Emby 登录和媒体库浏览。
4. 接入播放进度同步、继续观看和弹幕。
5. 最后补齐 MoviePilot、Bangumi、自动更新和高级画质功能。
