# Windows 背景架构

对齐参考是 GitHub `1824239290/OcPlayer` 的 `main` 提交
`888ccdd8a1098b4426166bb4b09b2f7dca3d8720`（2026-11-14），尤其是
`Docs/BACKGROUND-ARCHITECTURE.md`、`Docs/AMBIENCE.md`、`AppShell.swift`、
`AppModel+Ambience.swift`、`BackdropAmbienceView.swift` 和 `DetailPageFlip.swift`。
旧的本地 2026-09-04 macOS checkout 不作为此次实现依据。

## 覆盖与所有权

`MainWindow` 只挂一层 `AmbientBackdropView`，跨越标题栏与内容区。所有路由的
内容保持透明，背景不参与布局、命中测试和无障碍阅读。背景默认常开，没有设置开关。
首页、媒体库、观影、设置及设置子页都借用同一会话池；从任意页面启动都会装载池。
播放器由视频表面负责，不使用此背景。

`AmbientBackdropController` 持有会话池、换片计时器与加载取消令牌。经共享 Core 的
`browse.library` 查询 24 个随机电影/剧集，筛选实际有 backdrop 的条目、去重洗牌后
最多保留 8 张。失败时回退首页 latest/resume/nextUp。首张解码成功后才出现，剩余图片
预热后每 12 秒交叉淡入，换片时间 1.6 秒。普通导航与首页刷新不重抽成功的池；空池在
首页数据到位后重试。切换/断开服务器清除旧任务与鉴权图片缓存。

## 图片与合成预算

池图请求宽度 800、解码上限 512；统一 blur 80，放大 1.22。
背景层保持统一流光模糊与平滑遮罩，去除顶部薄雾反光：自顶端起平滑维持
内容雾度（深色 .48 / 浅色 .66），.85 高度沉回页面底色，底部实色。顶部由 112px
的 HeaderShade 遮罩提供标题栏对比度与压暗。

详情只请求一份 1600 宽 / 最多 1920 解码的原始 backdrop。进页先冻结池中已经缓存
的模糊小图；不为过渡图发新请求。条目像素就绪后清晰层与模糊层共用一个
`LoadedImageSurface`，完整图组以 .35 秒淡入。未加载或失败时保留进页快照/底色。
详情第一页左側 34% 完整模糊，再经 34% 的软边退到清晰图；正文页将实心遮罩
扩张到视口宽度的 1.75 倍。翻页、调整窗口和主题变化只改合成，不重新取图。
详情 blur 30、放大 1.15、saturation 1.02，白雾/黑纱与底部选集遮罩按 macOS 档位配置。

Windows Composition 驱动两个场景图组，Win2D 提供 GaussianBlur/Saturation 效果。
缓存只驻留会话内、上限 12 张，优先淘汰不用的详情大图；图片鉴权 URL 不写盘。
系统关闭动画时不轮播并直接提交转场；窗口失活时暂停计时，激活后继续。

## 验证

编译使用 `dotnet build src/OcPlayer.Windows/OcPlayer.Windows.csproj -c Debug -p:Platform=x64`。
共享 Core 的随机查询、无背景过滤、800/1600 宽度与鉴权保留可独立验证：

```powershell
dotnet run --project tests/OcPlayer.Integration -c Debug -p:Platform=x64 -- --server-only artifacts/background-server-verification
```

视觉检查应覆盖从设置冷启动、首页 → 设置 → 设置子页 → 返回时的背景连续性、
媒体库与观影、详情首屏/正文、明暗主题、窗口缩放、首次解码和缓存命中。
`RenderTargetBitmap` 不可靠地捕获 Composition 子视觉，实际背景验收使用窗口截图。
