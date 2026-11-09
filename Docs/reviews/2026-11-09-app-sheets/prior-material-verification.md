# macOS 弹窗半透明材质跟进

本次只修改共享 `AppSheet.swift`。

macOS 使用 Bangumi 原有的 `NSVisualEffectView`、`hudWindow`、`behindWindow` 与 0.62 明暗遮罩；系统保留唯一的圆角、边界与阴影。只清除当前 sheet 的窗口底色，父窗口不受影响。材质移除时恢复窗口设置，阻止已卸载材质的延迟回调再次改动窗口。减少透明度开启时使用实色背景。

iOS 去掉自定义 `presentationBackground`，交由系统 sheet 管理默认背景，保留之前的内容布局与尺寸策略。

## 验证

- macOS 最终编译通过：`macos-final-build.log`。
- iOS Simulator 编译通过：`ios-build.log`；最后的生命周期防护仅存在于 macOS 条件编译分支。
- 全部 9 种内容弹窗运行检查通过：sheet 为非不透明窗口、底色 alpha 为 0，配置 `hudWindow` 和 `behindWindow`；父窗口仍为不透明、底色 alpha 为 1。详见 `macos-preview-results.json` 与 `runtime-*.json`。
- 在实际可见的预览窗口中截图，核对深色 Bangumi、直连输入、MoviePilot 登录和浅色直连输入、订阅编辑；文字清晰且背景颜色与模糊轮廓透出。单窗口截图会丢失跨窗口模糊采样，因此最终视觉证据是 `macos-visible-*.png`。
- iOS 系统默认背景通过直连输入和 Bangumi 预览截图复核：`ios-native-*.png`。
- `git diff --check` 通过。本次纯材质修改未重跑业务逻辑测试。

原始截图、源码与旧报告保留；新记录独立存放。所有本次 macOS 预览进程均退出；iOS 临时预览 bundle `local.ocplayer.sheetpreview` 已终止并卸载。
