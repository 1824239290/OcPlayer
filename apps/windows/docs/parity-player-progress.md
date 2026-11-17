# 播放器补齐进度

基线审计：audit-player-2026-11-16.md。以下为当前工作树实现状态，尚未把静态接线冒充真实媒体验证。

## 已实现

- P01 更多菜单进入/退出全屏。
- P02 canRemove 字幕逐项删除、选中轨删除后重新使用默认策略、服务器删除项本会话不重装。
- P03/P04 实际杜比profile、输出编码、8/10/16bit 格式及 HDR 回退说明。杜比身份来自native解码事件，不通过猜测文件名。
- P05/P06/P07/B03 独立 Rate/Volume/Muted 保存及恢复，350ms 音量保存去抖，静音保留滑块。
- P08 直接调用共享 Core playbackTracks.selection，四档语言策略、同分稳定、用户显式选择不覆盖。
- P09/B01/B02/B05/B06 PreviewKeyDown/Up：右键按住350ms临时2x、恢复速率、独立徽章，音量10%，焦点控件统一键处理，开关键忽略重复，seek距EOF0.5秒。
- P10/P25 独立缓冲圈400ms延迟/250ms显示下限；缓冲不自动收起已显示HUD。
- P11/P12/P13/P14 加载层/取消、错误重试按钮及宿主事件、错误分类、60秒open watchdog。宿主准备/重取会话由root接线。
- P15/P16/P17/P18/P19/P20/P27 原生结束/视频尺寸及重试事件、宿主直放源排序/裸直连/最多3候选/连播/关闭/Bangumi/窗体fit已接线。独立复审修复了预取失败误当无下一集、旧结束回调跨重试推进以及超宽画面fit被高度钳制改变比例的问题。
- P21/P22/P23 Windows DisplayRequest、窗口SMTC元数据/位置/速率、系统播放暂停/前后跳转/改变位置，退出清理。
- P24/P26 HUD光标隐藏/移动恢复、屏幕阅读器SPI状态保留HUD。
- P28/P29/P30/P31/P35/P36 片头尾提示、最后90秒及尾声保留、服务器MediaSegments、章节启发式/合并、社区hint优先级、共享Core学习持久化。
- P32/P33/P34 查询部分由settings代理实现，播放器消费hint已实现；AutoLoad=false时另有取消/代次隔离的独立查询，不依赖弹幕渲染。
- P37 8秒无位置推进且非暂停/缓冲时写stall及恢复日志到统一AppDiagnostics（日志页可查看，不记录认证URL）。
- B04 侧车字幕最多4并发下载，按原始顺序挂载，逐请求超时与换片取消。

## 已验证

- 本次收尾完整媒体集成测试通过 341 条断言：`reports/continuation-full-integration-20261116b/results.json`。覆盖真实解码、字幕截图/缩放/关闭/重选/删除、弹幕、暂停/跳转/倍速、进度重启恢复及服务器报告顺序。
- 删除外挂字幕的真实媒体测试发现 native 命令排队导致即时列表读到旧轨道；已新增 worker 完成确认，并同步 Core 选中轨。选中/未选中字幕的连续删除均通过，不通过放宽断言掩盖问题。可重放补丁：`Scripts/patches/player-subtitle-removal.patch`。
- 原生 WinUI 验证已覆盖 swap chain/真实视频解码、XML 应用层弹幕、暂停、seek、字号/透明度/屏蔽、下一片源切换到内核渲染、JSON 内核弹幕、SMTC 元数据/播放状态与退出释放。最终记录见 [收尾报告](parity-completion-2026-11-16.md)。
- root统一native rebuild成功。
- Rust `source::tests::http_back_buffer_retains_and_bounds_previous_ranges`：1 passed / 0 failed。验证实际HTTP Source保留之前范围、旧字节读取、预算淘汰，非仅配置值测试。
- Rust `tests::c_event_exposes_video_decoder_transition_message`：1 passed / 0 failed。断言原生C事件JSON携带 `dolbyVisionProfile:5`。
- 可重放 `Scripts/patches/player-runtime-parity.patch` reverse apply check通过。
- `tests/OcPlayer.Integration/PlayerParityVerification.cs`（偏好迁移、静音、非有限值、章节合并/边界、电影时长门槛、来源优先级、错误分流、native字幕删除）已纳入完整 341 条集成断言并通过。
- UI回归新增临时2x徽章/恢复、独立静音滑块、seek EOF保护；沿用真实DispatcherTimer，不直接伪造Tick结果。
- UI首次执行揭示HUD焦点门槛将`PlayerView`自身误当控制按钮，导致播放器根节点键盘焦点时永不自动隐藏。实际SPI_GETSCREENREADER查询为成功/false；已修成只保护HUD后代焦点。重新构建后`reports/parity-ui-player-rerun-20261116.json`为passed=true：包括原3秒自动隐藏、读屏启用保持/禁用恢复、独立静音、临时2x、EOF保护、更多全屏及既有菜单/分享/退出恢复验证。读屏测试使用与production同一轮询入口的隔离provider，没有修改用户系统全局读屏状态。

## 待验证

- 系统媒体面板发出的物理命令、Narrator、物理长按键及自动重复、开片60秒超时、HDR/DV 实际画质仍需相应环境实测。统一 managed/UI/native 媒体测试已完成，不把硬件专项验收混入已通过结果。
- NetworkBuffer/BackBuffer/UA/字幕样式/ArtCNN全部已接真实native。BackBuffer补丁沿用C ABI保留槽位，默认16MiB，上限128MiB；包括来源读取的实际历史缓存，并非仅设置UI。
