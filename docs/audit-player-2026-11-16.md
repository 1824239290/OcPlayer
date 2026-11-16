# 播放器精细对照审计（分报告）

基线：OcPlayer GitHub main `888ccdd8a1098b4426166bb4b09b2f7dca3d8720`（2026-11-14），源目录 `D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720`。Windows 为 `D:/OcPlayer-Windows` 当前工作树（包括未提交文件），最终复核截止 2026-11-16 04:17 HKT。本次仅静态源码与调用链核对，未宣称逐项真实媒体实机通过。

审计时 Windows 另一个工作流正在修改播放器。早期发现的 More/Tracks 生命周期未接线，在最终复查前已经补齐，**已从缺失清单删除**。播放器设置页的缓冲、默认字幕语言/样式、画质等选项由设置分报告列出；本报告只补其实际播放行为。

## 明确缺失或部分支持

| 编号 | 状态 | 功能粒度 | 原版与Windows差异 | 原版证据 | Windows证据 |
|---|---|---|---|---|---|
| P01 | 菜单项缺失 | “更多”里的“进入全屏 / 退出全屏” | 原版在更多菜单保留此项；Win 更多菜单只有倍速、播放信息、截图和条件分享。Win 顶栏全屏按钮、F 键、双击全屏已存在，因此缺的是这一处入口。 | [1] | [2] |
| P02 | 缺失 | 删除一条外挂字幕 | 原版字幕轨道行按 canRemove 显示删除按钮；Win 只有单选轨道/关闭字幕/导入，没有删除入口，也没有调用 removeSubtitleTrack。删除当前轨后重新按偏好选择的配套行为也缺。 | [3] [4] | [5] [6] |
| P03 | 部分 | 播放信息：杜比视界状态 | 原版能区分“杜比视界”“杜比视界（映射 SDR）”“杜比视界（HDR）”。Win 仅按 transfer=16/18 判断 HDR(PQ)/HLG，其余 SDR，没有杜比源身份参与。此处是信息显示缺口，不能据此断言 Windows 不支持杜比解码。 | [7] | [8] |
| P04 | 缺失 | 播放信息：“输出”行 | 原版显示实际输出编码（SDR / Apple EDR / HDR10 PQ / 扩展线性）、面格式（8bit / 10bit / 16bit 浮点）及 HDR 回退原因；Win 虽有 GetOutputStatus 适配器方法，信息面板未读取或显示。 | [9] [10] | [11] [12] |
| P05 | 缺失 | 记住播放倍速 | 原版跨启动保存 rate，临时快进除外；Win 每个新 PlayerView 从 1× 开始，SetRate 只下发当前会话。 | [13] [14] | [15] [16] |
| P06 | 缺失 | 记住音量 | 原版音量去抖落盘并在开片恢复；Win 滑块初值40，只有当前实例数值，没有音量设置读写。 | [17] | [18] [19] |
| P07 | 缺失 | 记住静音状态 | 原版 muted 独立保存；Win 用 Volume=0 临时模拟静音，仅在当前实例用 _previousVolume 记住原音量，新播放器丢失。 | [20] | [21] |
| P08 | 部分 | 按字幕语言偏好自动选轨 | 原版轨道刷新后支持“简中优先 / 繁中优先 / 跟随文件默认 / 默认关闭”，识别语言和显示名，用户手动选择后本片不再覆盖；原版没有 English 这一档。Win 仅新增服务器侧车字幕在“原来没字幕”时按 zh/chi 粗选一条；不会校正已选中的内封首轨，也不区分简繁或默认关闭。设置项详见设置审计。 | [22] [109] | [23] |
| P09 | 缺失 | 右方向键长按临时2倍速 | 原版按住右箭头进入临时2×，松手/失焦/离开播放器恢复原速，并显示独立2×徽章；Win 右箭头只 Seek(+10)，没有长按状态、恢复或徽章。 | [24] [25] | [26] |
| P10 | 缺失 | 缓冲中指示 | 原版持续缓冲时显示独立中央转圈，短促饥饿经迟滞过滤，HUD关闭也可见。Win 采集 Buffering，但仅用于信息面板的状态字，没有画面转圈或迟滞UI状态。 | [27] | [28] [29] |
| P11 | 缺失 | 准备播放的加载层和取消入口 | 原版从解析播放地址到首帧前保留加载遮罩、片名、取消按钮；Win Play 直接等待 Resolve，失败 Notify，播放器打开后黑背景和控制条，没有对应准备层及明确“取消准备”按钮。返回上页或关闭窗口的间接取消不等同该入口。 | [30] [31] | [32] [33] |
| P12 | 缺失 | 播放错误处原地重试 | 原版准备失败和播放错误徽章都有重试，服务器媒体重新取 PlaybackInfo/会话并按进度恢复；Win InfoBar 仅展示/关闭，Failed 统一 retryable=false，无重试按钮。 | [34] [35] | [28] [36] |
| P13 | 缺失 | 错误类型提示和恢复分流 | 原版区分网络/格式不支持/鉴权/服务器/已取消/未知，并据此决定换源/重试；Win 原生播放失败统一归 decode，显示原始 message。 | [37] | [36] |
| P14 | 缺失 | 开片60秒超时保护 | 原版引擎open超过60秒取消、停止并显示超时，回收挂起开片槽位；Win PlaybackSession.Open/Tick 只等待原生事件，无宿主级open watchdog。此项不等于否认原生HTTP自身可能有超时。 | [38] | [39] [40] |
| P15 | 缺失 | PlaybackInfo失败后直连回退 | 原版准备工作流在 PlaybackInfo 失败后尝试裸直连；Win Resolve 对 playback.info 直接 await，异常回上层 Notify，未走回退。 | [41] [42] | [43] |
| P16 | 缺失 | 优先选择可直放的媒体源 | 原版按 DirectPlay → DirectStream → 首条的策略选择；Win 无条件 sources[0]。同一个条目多个版本/媒体源时可能选错首选。 | [44] | [45] |
| P17 | 缺失 | 开片失败自动尝试备用媒体源 | 原版构建候选源并按错误类型自动切换，最多3次，最后回到可手动重试的错误态；Win PlaybackSource 只存一个URI，没有替代源和恢复流。 | [46] [47] | [48] [49] |
| P18 | 缺失 | 自然播完自动下一集 | 原版预取下一集（排除特殊篇），达到末尾自动开下一集；Win state=5 仅置停止、存进度、上报，无下一集回调。 | [50] [51] | [52] |
| P19 | 缺失 | 没有下一集时自动退出播放器 | 原版自然结束而没有下一集 dismissPlayer；Win停在播放器末尾，须手动返回。 | [53] | [52] |
| P20 | 缺失 | 自然看完同步Bangumi章节已看 | 原版有关联且登录时按集号标记 Bangumi 章节已看，失败不阻断连播；Win结束链仅本地进度和Jellyfin/Emby停止上报，没有触发 Bangumi 集数同步。 | [54] | [55] |
| P21 | 缺失 | 播放期间防息屏 | 原版只在实际播放期间持有防显示器休眠令牌，暂停/错误/退出释放。Win 前端与适配器没有 DisplayRequest/SetThreadExecutionState/PowerRequest 对应实现。 | [56] [57] | [58] |
| P22 | 缺失 | 系统“正在播放”信息 | 原版发布片名、集名、时长、当前位置、速率、播放/暂停状态，退出清除；Win 无 SystemMediaTransportControls/媒体会话发布。 | [59] | [58] |
| P23 | 缺失 | 系统媒体控制命令 | 原版响应系统播放、暂停、切换播放暂停、前后10秒、改变进度；Win只有播放器焦点范围内的普通键盘快捷键，无媒体键/系统媒体面板命令注册。 | [60] | [61] |
| P24 | 缺失 | HUD隐藏时自动藏鼠标指针 | 原版HUD隐藏后指针隐藏到下一次移动，唤醒/退出恢复；Win仅改变HUD透明度和可命中性，未设置 ProtectedCursor/光标隐藏。 | [62] | [63] |
| P25 | 部分 | 持续缓冲时保留已展开HUD | 原版把缓冲纳入禁止自动隐藏条件，不会因此强弹HUD；Win3秒隐藏条件仅检查 playing、scrubbing、菜单、hover、focus，不检查 Buffering。 | [64] | [65] |
| P26 | 部分 | 读屏辅助功能下保留HUD | 原版 VoiceOver 开启会禁止HUD自动收起；Win已有控件Automation名称和键盘焦点保护，但没有读屏开启条件，Narrator运行时仍按普通3秒规则隐藏。 | [66] | [65] |
| P27 | 缺失 | 按视频比例自动调整窗口并恢复 | 原版视频尺寸就绪后fit窗口比例，退出还原原窗口尺寸；Win只监听用户窗口变化去Resize原生surface，不按视频尺寸调整窗口。恢复全屏presenter已经有，不等于恢复按比例调整的窗口。 | [67] [68] | [69] [70] |
| P28 | 缺失 | “跳过片头”悬浮按钮 | 原版位于有效片头区间时显示，点击跳区间末尾并避免重复提示；Win没有SkipPrompt UI/状态。 | [71] [72] | [73] |
| P29 | 缺失 | “跳过片尾”悬浮按钮 | 原版支持准确片尾区间，并在最后90秒提供保底跳过（按设置保留尾声，尾部0.5秒保护）；Win只有普通±10秒/时间轴/章节跳转。 | [74] [75] | [76] |
| P30 | 缺失 | 服务器MediaSegments片头/尾识别 | 原版读服务端Intro/Outro区间，作为最高优先级；Win章节服务只调用 browse.chapters，无mediaSegments调用。 | [77] | [78] |
| P31 | 缺失 | 章节名/位置推断片头片尾 | 原版支持OP/ED等名字及位置/时长兜底、相邻同类章节合并、电影较长片尾上限；Win只构建Name/Start/End供手动跳章节，没有识别规则。 | [79] | [80] |
| P32 | 缺失 | AniSkip片头时间源 | 原版以社区标注补充片头提示；Win danmaku请求明确 aniSkip.enabled=false，播放器也无另一条查询/消费链。 | [81] [82] | [83] |
| P33 | 缺失 | anime-skip片头时间源 | 原版有配置Client ID后启用的社区时间戳；Win provider关闭且无播放器消费链。 | [84] | [83] |
| P34 | 缺失 | TheIntroDB片头时间源 | 原版用TMDB身份查TheIntroDB；Win provider关闭且无播放器消费链。 | [85] | [83] |
| P35 | 缺失 | 弹幕报点推断片头 | 原版将弹幕推导的introHint传给播放器，低于服务器/社区信号优先级；Win弹幕加载只渲染，无将introHint变成SkipPrompt的调用。 | [86] [87] | [88] |
| P36 | 缺失 | 从用户快进学习片头 | 原版监听主动seek，持久化学习，后续同作品用于片头提示并按来源优先级合并；Win Seek/SetPosition只更新时间轴/内核，不记学习。 | [89] [90] | [91] |
| P37 | 缺失 | 播放卡住的诊断监测 | 原版在非暂停非缓冲下检测位置不前进，记录stall与恢复事件；Win只轮询状态/进度，没有宿主stall识别。此项是故障诊断能力，非新增按钮。 | [92] | [58] |

## 交互口径差异（有替代操作，不计为整项功能缺失）

| 编号 | 差异 | 证据 |
|---|---|---|
| B01 | 上下方向键原版每次音量±10%，Windows为±5%。 | [93] [94] |
| B02 | 原版点击滑块后，空格/方向键仍归播放器；Windows有键盘焦点的Slider、Button会保留控件自身键行为，播放器不接管。该差异是原生控件选择，是否要求严格一致由产品决定。 | [95] [96] |
| B03 | 原版静音为独立mute状态，滑块保留原音量；Windows把滑块直接归零，再用_previousVolume恢复。 | [97] [21] |
| B04 | 原版字幕侧车下载最多4并发并按原顺序挂载；新Windows实现逐个await下载，且整批2分钟超时。大量侧车字幕/慢源加载体验未对齐。 | [98] [99] |
| B05 | 原版常规开关键忽略autorepeat；Windows KeyboardAccelerator没有显式重复抑制，实际系统是否重入需要按住Space/Enter/M/F实测，不直接判为已发生缺陷。 | [100] [101] |
| B06 | 原版±10秒快进等有距片尾0.5秒的seek保护；Win可钳到精确片长。内核版本影响实际结果，应针对EOF播放错误实测。 | [102] [76] |

## 已对齐的重要按钮与选项（防止误报）

- 返回、顶部全屏、双击全屏、单击HUD、播放/暂停、前后10秒、时间轴拖拽、当前位置/总时长、集号与剧名、音量滑块和静音都已有；Space/Enter/←/→/J/L/↑/↓/M/F/Esc均有绑定。
- “更多”→播放速度的 **0.5、0.75、1、1.25、1.5、2倍**完全一致，没有缺1.75倍（原版本来也无该选项）。播放信息、画面截图、条件分享已接入；不能再写成缺失。
- 音轨单选、无多音轨提示；字幕轨道单选、关闭字幕、打开外挂字幕（ASS/SSA/SRT/VTT）、外挂显示名；字幕字号减小/重置/加大（50%–300%、10%步进）已有。缩放偏好落盘、恢复及开片应用现已接上。
- 服务器章节列表、时间点、点击跳转、当前章节播放高亮现已接入；Win额外有章节加载/失败重试状态。不能再写“没有章节功能”。
- HUD3秒隐藏、菜单/滑块拖动/键盘焦点期间保留、窗口变窄调整尺寸、系统减弱动画、出错提示、原生进度保存/续播、服务器开始/进度/停止上报已有。
- 服务端侧车字幕已补齐到调用链：`PlayerView.ServerSubtitles.cs`与`ServerSubtitleService.cs`已有下载、取消、换片隔离、失败重试和中文兜底。04:17最终复查已确认主播放器在101/180/204行分别调用ResetServerSubtitles、StartServerSubtitlesIfReady、DisposeServerSubtitles，**不再属于待接线或整项缺失**；自动语言偏好差异见P08。

## Apple平台能力与待验证项

- iOS画面手势：双击播放暂停、长按临时2×、横滑进度预览/松手提交、左半屏纵滑亮度、右半屏纵滑系统音量，Windows没有等价触屏手势；这是相对iOS端的差异，不能冒充macOS现有功能。源：[103] [104]。
- iOS后台仅音频播放、前后台解码恢复、音频中断后恢复、系统音量桥、刘海/灵动岛安全区属于平台专属；Windows最小化/换音频设备效果应单测，而不是照抄UIKit机制。源：[105] [106]。
- 原版macOS会上报当前屏幕EDR headroom并随换屏更新；Windows适配器固定OutputMode=3、headroom=10000/203，但Windows原生输出链可能自行探测能力。现有代码足以确认信息面板字段缺失（P03/P04），不足以直接判定HDR/杜比视觉效果缺失；需SDR/HDR双屏实测。源：[107] [108]。
- 原版本地文件并未提供独立容器章节提取（只服务端章节+保底片尾），因此不把“本地章节提取”当Windows落后项；画中画也不能因占位图标像PiP就写为原版现有功能。

## 证据定位

[109]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/PlaybackKit/Sources/PlaybackKit/SubtitleSelection.swift:11> "SubtitleLanguagePreference"

[1]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDActions.swift:555> "App/Shared/Features/Player/PlayerHUDActions.swift:555"
[2]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.More.cs:126> "src/OcPlayer.Windows/Features/PlayerView.More.cs:126"
[3]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDActions.swift:693> "App/Shared/Features/Player/PlayerHUDActions.swift:693"
[4]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController+Tracks.swift:258> "App/Shared/Features/Player/PlaybackController+Tracks.swift:258"
[5]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.Tracks.cs:177> "src/OcPlayer.Windows/Features/PlayerView.Tracks.cs:177"
[6]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:195> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:195"
[7]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDChrome.swift:317> "App/Shared/Features/Player/PlayerHUDChrome.swift:317"
[8]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.More.cs:187> "src/OcPlayer.Windows/Features/PlayerView.More.cs:187"
[9]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDChrome.swift:139> "App/Shared/Features/Player/PlayerHUDChrome.swift:139"
[10]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDChrome.swift:375> "App/Shared/Features/Player/PlayerHUDChrome.swift:375"
[11]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.More.cs:42> "src/OcPlayer.Windows/Features/PlayerView.More.cs:42"
[12]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:216> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:216"
[13]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:153> "App/Shared/Features/Player/PlaybackController.swift:153"
[14]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackPreferences.swift:33> "App/Shared/Features/Player/PlaybackPreferences.swift:33"
[15]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:26> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:26"
[16]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:271> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:271"
[17]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:162> "App/Shared/Features/Player/PlaybackController.swift:162"
[18]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml:77> "src/OcPlayer.Windows/Features/PlayerView.xaml:77"
[19]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:70> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:70"
[20]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:181> "App/Shared/Features/Player/PlaybackController.swift:181"
[21]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:426> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:426"
[22]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController+Tracks.swift:306> "App/Shared/Features/Player/PlaybackController+Tracks.swift:306"
[23]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.ServerSubtitles.cs:113> "src/OcPlayer.Windows/Features/PlayerView.ServerSubtitles.cs:113"
[24]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift:923> "App/Shared/Features/Player/PlayerScreen.swift:923"
[25]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:1944> "App/Shared/Features/Player/PlaybackController.swift:1944"
[26]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:77> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:77"
[27]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift:166> "App/Shared/Features/Player/PlayerScreen.swift:166"
[28]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml:161> "src/OcPlayer.Windows/Features/PlayerView.xaml:161"
[29]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.More.cs:174> "src/OcPlayer.Windows/Features/PlayerView.More.cs:174"
[30]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreenComponents.swift:7> "App/Shared/Features/Player/PlayerScreenComponents.swift:7"
[31]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift:458> "App/Shared/AppModel+Playback.swift:458"
[32]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:271> "src/OcPlayer.Windows/MainWindow.xaml.cs:271"
[33]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:122> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:122"
[34]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreenComponents.swift:124> "App/Shared/Features/Player/PlayerScreenComponents.swift:124"
[35]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift:844> "App/Shared/AppModel+Playback.swift:844"
[36]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:259> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:259"
[37]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackOpenError.swift:24> "App/Shared/Features/Player/PlaybackOpenError.swift:24"
[38]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:1132> "App/Shared/Features/Player/PlaybackController.swift:1132"
[39]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:57> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:57"
[40]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:85> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:85"
[41]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift:99> "App/Shared/AppModel+Playback.swift:99"
[42]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/JellyfinKit/Sources/JellyfinKit/PlaybackPreparationWorkflow.swift:87> "Packages/JellyfinKit/Sources/JellyfinKit/PlaybackPreparationWorkflow.swift:87"
[43]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:273> "src/OcPlayer.Windows/Services/MediaServer.cs:273"
[44]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/JellyfinKit/Sources/JellyfinKit/PlaybackInfo.swift:127> "Packages/JellyfinKit/Sources/JellyfinKit/PlaybackInfo.swift:127"
[45]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:276> "src/OcPlayer.Windows/Services/MediaServer.cs:276"
[46]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift:202> "App/Shared/AppModel+Playback.swift:202"
[47]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift:211> "App/Shared/AppModel+Playback.swift:211"
[48]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:5> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:5"
[49]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:254> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:254"
[50]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift:907> "App/Shared/AppModel+Playback.swift:907"
[51]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift:918> "App/Shared/AppModel+Playback.swift:918"
[52]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:119> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:119"
[53]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift:921> "App/Shared/AppModel+Playback.swift:921"
[54]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift:924> "App/Shared/AppModel+Playback.swift:924"
[55]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:125> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:125"
[56]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackWakeLock.swift:27> "App/Shared/Features/Player/PlaybackWakeLock.swift:27"
[57]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:443> "App/Shared/Features/Player/PlaybackController.swift:443"
[58]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:168> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:168"
[59]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackNowPlayingCenter.swift:195> "App/Shared/Features/Player/PlaybackNowPlayingCenter.swift:195"
[60]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackNowPlayingCenter.swift:274> "App/Shared/Features/Player/PlaybackNowPlayingCenter.swift:274"
[61]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:75> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:75"
[62]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift:772> "App/Shared/Features/Player/PlayerScreen.swift:772"
[63]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/PlayerHudVisibilityController.cs:31> "src/OcPlayer.Windows/Services/PlayerHudVisibilityController.cs:31"
[64]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDGates.swift:17> "App/Shared/Features/Player/PlayerHUDGates.swift:17"
[65]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:194> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:194"
[66]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDGates.swift:23> "App/Shared/Features/Player/PlayerHUDGates.swift:23"
[67]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift:421> "App/Shared/Features/Player/PlayerScreen.swift:421"
[68]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/macOS/PlayerWindowFitter.swift:1> "App/macOS/PlayerWindowFitter.swift:1"
[69]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:297> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:297"
[70]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:324> "src/OcPlayer.Windows/MainWindow.xaml.cs:324"
[71]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift:220> "App/Shared/Features/Player/PlayerScreen.swift:220"
[72]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDActions.swift:1004> "App/Shared/Features/Player/PlayerHUDActions.swift:1004"
[73]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml:118> "src/OcPlayer.Windows/Features/PlayerView.xaml:118"
[74]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackChapter.swift:338> "App/Shared/Features/Player/PlaybackChapter.swift:338"
[75]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:1773> "App/Shared/Features/Player/PlaybackController.swift:1773"
[76]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:264> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:264"
[77]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:1841> "App/Shared/Features/Player/PlaybackController.swift:1841"
[78]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/PlaybackChapters.cs:17> "src/OcPlayer.Windows/Services/PlaybackChapters.cs:17"
[79]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackChapter.swift:147> "App/Shared/Features/Player/PlaybackChapter.swift:147"
[80]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/PlaybackChapters.cs:50> "src/OcPlayer.Windows/Services/PlaybackChapters.cs:50"
[81]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackChapter.swift:48> "App/Shared/Features/Player/PlaybackChapter.swift:48"
[82]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:365> "App/Shared/Features/Player/DanmakuCoordinator.swift:365"
[83]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:134> "src/OcPlayer.Windows/Services/DanmakuService.cs:134"
[84]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:377> "App/Shared/Features/Player/DanmakuCoordinator.swift:377"
[85]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:380> "App/Shared/Features/Player/DanmakuCoordinator.swift:380"
[86]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:767> "App/Shared/Features/Player/DanmakuCoordinator.swift:767"
[87]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:1756> "App/Shared/Features/Player/PlaybackController.swift:1756"
[88]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuCoordinator.cs:1> "src/OcPlayer.Windows/Services/DanmakuCoordinator.cs:1"
[89]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:789> "App/Shared/Features/Player/DanmakuCoordinator.swift:789"
[90]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:1664> "App/Shared/Features/Player/PlaybackController.swift:1664"
[91]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:263> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:263"
[92]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:1388> "App/Shared/Features/Player/PlaybackController.swift:1388"
[93]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift:961> "App/Shared/Features/Player/PlayerScreen.swift:961"
[94]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:79> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:79"
[95]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift:914> "App/Shared/Features/Player/PlayerScreen.swift:914"
[96]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:291> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:291"
[97]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:1968> "App/Shared/Features/Player/PlaybackController.swift:1968"
[98]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift:1116> "App/Shared/AppModel+Playback.swift:1116"
[99]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.ServerSubtitles.cs:56> "src/OcPlayer.Windows/Features/PlayerView.ServerSubtitles.cs:56"
[100]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift:947> "App/Shared/Features/Player/PlayerScreen.swift:947"
[101]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:283> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:283"
[102]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:1638> "App/Shared/Features/Player/PlaybackController.swift:1638"
[103]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift:471> "App/Shared/Features/Player/PlayerScreen.swift:471"
[104]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift:518> "App/Shared/Features/Player/PlayerScreen.swift:518"
[105]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift:1423> "App/Shared/Features/Player/PlaybackController.swift:1423"
[106]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackAudioInterruptions.swift:1> "App/Shared/Features/Player/PlaybackAudioInterruptions.swift:1"
[107]: <D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift:337> "App/Shared/Features/Player/PlayerScreen.swift:337"
[108]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/ErikaPresenter.cs:17> "src/OcPlayer.CoreAdapter/ErikaPresenter.cs:17"

