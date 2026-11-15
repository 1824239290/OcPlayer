# macOS 对照 Demo 验证

2026-11-15 从 Gitea `872ecc4` 同步后，以本机安装的 OcPlayer macOS App 的实际界面和当前 Swift 源码为参考修改 Windows 离线 Demo。

## 参考

本地完整参考图位于 `reports/macos-parity-2026-11-15/macos/`，共整理 26 张至桌面 `OcPlayer-macOS截图-2026-11-15`，附 `截图索引.html` 和 `macOS-Windows对照.html`；Windows 对照原图也一并复制到桌面。包含首页上下半页、电视剧媒体库、详情首屏、选集及第二页演员/媒体信息、播放器与字幕菜单、观影长页、设置总览和十个子页。参考图保留完整 PNG；它们包含当前账号/设置，仅在本地保存，不提交仓库。

Demo 图像来自本机已有的 OcPlayer 图片缓存与参考截图中的纯媒体图像裁切。原始文件保留在本地缓存和 `reports/macos-parity-2026-11-15/artwork-originals/`。应用中的界面、文本、导航及控件均为 WinUI 实现。

## 修改

- 首页沿用实际卡片尺寸和间距，栏目支持排序及显隐；补上接下来看，更新最近添加及继续观看素材、标题。
- 媒体库使用海报网格，搜索/排序/观看筛选位于顶栏；从详情返回保留网格的滚动位置。
- 详情背景覆盖标题栏，左侧为 Logo、元信息、标签、简介和播放/已看按钮，底部为季/集号与分集剧照。未来未入库集保留禁用占位；滚轮进入第二页的分集、Bangumi 章节、MoviePilot 入口、演员、媒体信息及类似推荐，顶部反向滚动返回首屏。
- 设置沿用服务、播放与界面、应用三组及十个子页；演示偏好在当前会话内保存，首页栏目开关和集成开关影响对应页面。
- 观影空间沿用头像、放送、观看记录/活跃度、片单、月度统计、最近观看、续播、订阅及下载顺序，数据为固定的离线样例。
- 播放器采用左上关闭/全屏、右上音量、中央跳转/播放、底部标题/菜单/进度的布局；支持模拟时钟、暂停、跳转、倍速、静音及全屏，拖动进度时不被时钟覆盖。

## Windows 验证方法

在局域网 Windows 用户的交互式桌面启动应用，使用 .NET SDK 10.0.404 / Windows App Runtime 2.6.5 构建。测试目录 `C:\Users\15199\OcPlayer-Demo-20261115` 与现有 Windows checkout 分开。

```powershell
dotnet build OcPlayer.sln -c Debug -p:Platform=x64
```

Debug 构建可指定初始页面并导出实际 WinUI 根视觉的 PNG：

```powershell
OcPlayer.Windows.exe --demo-route=detail --demo-capture=C:\Temp\detail.png
OcPlayer.Windows.exe "--demo-route=settings:播放" --demo-capture=C:\Temp\playback.png
```

截图参数仅在 Debug 有效；页面加载三秒后捕获并退出。它验证页面实际加载及绘制，不能替代按钮、系统标题栏或视频解码测试。此次对首页、媒体库、详情、观影、设置、播放器和十个设置子页以及详情第二页共 17 个页面执行启动/截图检查，图与结果保存在本地 `reports/macos-parity-2026-11-15/windows/`。

## 当前差异

Windows 系统窗口按钮、字体、图标与 macOS 不同；浏览背景已改为常开的整窗随机背景池，详情页使用同像素的清晰/模糊图组与可扩张遮罩。卡片仍为 WinUI 半透明表面，未实现 Liquid Glass 的实时采样和折射。观影统计图形细节、播放器菜单的嵌套内容和集成登录/管理对话框与原版仍有差异；集成操作以离线示例承载。显式 Demo 播放器为静态画面与模拟时钟，默认模式的真实 Core/Erika 播放验证见 `core-integration.md`。

原工作区的 Core Adapter 改动已保留；同步前的主窗口 Core 启动/表面实验完整保存在 `preserve local core integration before demo sync 2026-11-15` Git stash，默认 Demo 不创建 Core 或绑定视频表面。

最终 Debug 构建：0 警告、0 错误。17 个页面的退出码均为 0，均成功捕获 PNG，XAML 根视觉为 1130 × 700。截图捕获模式暂停模拟时钟，以便比较 HUD。
