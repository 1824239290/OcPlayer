# 共享弹窗 review — 2026-11-09

基于主分支 `e769cce` 审查 12 个弹窗相关文件；不重复包含已合并的内核升级、Bangumi 搜索和 seek 修改。未发现阻碍提交或合并的缺陷。

- 共享系统 sheet 尺寸、标题、字段和底栏；macOS 保持跨窗口模糊、减少透明度回退，并在材质卸载时恢复窗口状态；iOS 使用系统背景。
- TMDB 改为选择候选后确认；输入变化取消旧搜索，请求身份和取消检查防止旧结果回写，绑定失败保留选择。
- 表单提交期间禁止重复提交、编辑与关闭；订阅站点选择保留已有字段与站点设置。
- 复核已存档的实际 sheet 截图：窄屏、大字号、滚动空间、底栏按钮与半透明边界。此前布局记录的 11 个修改文件哈希均与此次一致；共享材质文件与后续材质记录一致。`source-sha256.json` 记录此次源码。

验证使用 Xcode 27.1 与仓库锁定的依赖版本：

- macOS Debug 构建及 6 个相关 AppTests 套件通过。xcresult 汇总：唯一用例 / executed / passed = 74 / 74 / 74；skipped = 0；failed = 0。套件为 DirectLinkInputTests、BangumiMatcherTests、TMDbCoordinatorTests、DanmakuPlaybackContextTests、MoviePilotSubscribeIndexTests、ServerAddressStatusTests；不含 SwiftPM 独立测试。
- iOS Simulator Debug（arm64、x86_64）构建通过。
- `git diff --check` 通过。

原始构建/测试输出完整压缩保存在 `validation-logs.zip`，结果汇总为 `macos-regression-summary.json`。原始工作区代码、截图与报告完整保留；此处截图为验收证据副本。截图复核依赖已存档的原生预览，此轮未重新连接真实远端服务做端到端交互。
