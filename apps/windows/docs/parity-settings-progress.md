# 设置、维护与弹幕补齐进度

基准：原版 `888ccdd8a1098b4426166bb4b09b2f7dca3d8720`。本文件记录实现与验证状态，不能替代真实账号、GPU 与各媒体源的最终验收。对应原审计 `audit-settings-danmaku-2026-11-16.md`。

## 收尾状态

实现已接入统一应用，Debug、Release 前端和 integration 工程均成功构建。完整真实媒体及本地 HTTP/持久化测试通过 **341 条断言**，原先 OAuth/别名用例的失败已关闭；通过文件为 `reports/continuation-full-integration-20261116b/results.json`。

应用层弹幕的 XML 导入、暂停时钟、seek、实时字号/透明度/屏蔽和换片 renderer 隔离已在真实 WinUI/原生解码器中通过。设置 UI、各档位与全部许可入口的当前证据见 [补齐收尾报告](parity-completion-2026-11-16.md)。下方第一、第二阶段表格保留历史分工及当时状态，不能据其中“待集成”推断当前仍未接线。

## 第一阶段实现（2026-11-16）

| 编号 | 实现 | 当前验证状态 |
|---|---|---|
| S-001 | 媒体服务器页增加上次使用/保存服务器选择；调用 ServerProfiles.SetDefault | 父任务负责启动恢复；待集成 |
| S-002 | RuntimeSettings 过滤控制字符、持久化 UA；网络页真实保存 | 父任务接媒体浏览/拉流；新增持久化测试 |
| S-003 | 2/8/16/32 MiB 全档设置 | 播放器 agent 负责 native 应用；待集成 |
| S-004 | 16/32/64/128 MiB 全档设置 | 播放器 agent 正补内核 back buffer；待集成 |
| S-005 | 默认开启的片头开关及 Changed 事件 | 播放器 agent 消费；待集成 |
| S-006 | 默认开启的片尾开关、关闭禁用保留选择 | 播放器 agent 消费；待集成 |
| S-007 | 0/5/10/15/20/30 秒选择 | EOF 安全由播放器 agent 验证 |
| S-008 | 简体/繁体/文件默认/关闭四档 | 播放器 agent 使用共享 Core 选轨策略 |
| S-009 | 不设置/底中/左下/右下/顶中 | RuntimeSettings 与实时事件已接；待播放器验证 |
| S-010 | 0–200、步长 10 | 新增边界/备份测试；待播放器验证 |
| S-011 | #RRGGBBAA 输入、含透明度 ColorPicker、单项还原 | 新增持久化/备份 alpha 测试 |
| S-012 | 描边 #RRGGBBAA、颜色选择、单项还原 | 新增持久化/备份测试 |
| S-013 | 0–32、步长 1 | 新增最大值备份测试 |
| S-014 | 未设置/true/false 三态及还原 | 新增明确 false roundtrip 测试 |
| S-015 | 覆盖 ASS 样式开关、即时 Changed | 播放器 agent 负责 native subtitle style |
| S-016 | off/F16/F32/F16 去噪四档，说明后端回退 | 播放器 agent 负责 native 应用；GPU 待验 |
| S-017 | 读取 build receipt 的 kernelVersion，核验 DLL SHA256 | 父任务构建脚本提供真实 receipt；无版本明确显示未知 |
| S-018 | PasswordVault 保存/替换 v3/v4 凭据、空输入禁用 | 真实 TMDB 请求 fixture + 备份测试 |
| S-019 | zh-CN/zh-TW/en/ja/ko；调用 Core 英文回退 | 新增双语言 HTTP fixture |
| S-020 | 默认文本优先、关闭只补缺字段 | Enrich 真实改写详情；待 fixture |
| S-021 | 图片替换/只补缺字段 | 真实改写海报/背景/分集图；待 fixture |
| S-022 | 未配置凭据仍可切换占位偏好 | Tmdb 占位已接；父任务接 Bangumi 兜底 |
| S-023 | 独立镜像开关、下次请求读取 | HTTP fixture 真实访问镜像 |
| S-024 | API 地址校验、补 /3、保留代理路径 | 新增规范化测试 |
| S-025 | 图片地址补 /t/p、去尺寸和图片段、空值官方回退 | 新增规范化测试 |
| S-026 | 当前 API/图片地址预览 | 设置页实际生效值 |
| S-027 | 官方备用 API 域快捷填充 | 设置页调用真实 Save |
| S-028 | 清镜像地址并关镜像 | 设置页调用真实 Save |
| S-029 | 分页遍历电影/剧集并补所有季；持久化缓存与关联 | 代码落地；批量 fixture 待补 |
| S-030 | 完成/总数/当前标题/新补/跳过/不匹配/失败/季数、上次报告 | batch.json 保存；待批量测试 |
| S-031 | 取消、页面退出取消；成功结果保留 | 代码落地；待取消测试 |
| S-032 | 有效关联计数、确认后清缓存和关联 | 新增关联/清理测试 |
| S-033 | SHA256 文件名真实图片缓存，512 MiB 限额/用量 | 父任务接海报；新增下载 fixture |
| S-034 | 确认清理、禁用按钮、等待旧下载、更新用量 | 新增真实文件删除测试 |
| S-035 | Core metadataDatabase.size 读真实 sqlite/WAL/SHM | 设置页调用真实 Core；待 UI 验证 |
| S-036 | 确认后 cache.clear 当前 tenant，反馈 | 设置页调用真实 Core；待 tenant 测试 |
| S-037 | 导出原版兼容 JSON + Windows 扩展；不含服务器账号 | 新增真实 Core decode + roundtrip |
| S-038 | 系统文件选择、全面预检、确认后恢复各实际 store | 新增恢复实际偏好测试 |
| S-039 | 时间/设备/Key 尾/语言/各偏好预览 | 新增敏感值隐藏断言 |
| S-040 | 独立详细日志默认关闭、即时过滤；内核下次开流 | 新增日志级别测试；内核由播放器 agent |
| S-041 | 文件名/完整路径点击切换 | UI 已接 |
| S-042 | 后台逐行读取实际条数/大小 | AppDiagnostics.Read；新增日志测试 |
| S-043 | 展开最近 100 条、级别/时间/抑制数、选择/复制、空状态 | UI 已接 |
| S-044 | 系统保存选择 + Core diag.exportFile 导出实际日志/诊断 | UI 已接；导出文件待验 |
| S-045 | 确认清日志、刷新摘要 | UI 已接；测试真实清理 |
| S-046 | 弹幕诊断独立开关；匹配状态即时写日志 | 新增与详细日志互不依赖测试 |
| S-047 | Assembly 信息版本和 Build | UI 已接 |
| S-048 | 真实 Windows release feed、检查/最新/新版/失败重试 | 新增本地 HTTP 更新 fixture |
| S-049 | CheckAutomaticUpdate API、忽略版过滤、release sheet | 父任务接启动钩子 |
| S-050 | 版本/日期/可选择日志/无日志兜底 | 真实 release sheet |
| S-051 | ignored-release.txt 持久化；手动仍可看 | 新增持久化测试 |
| S-052 | 前往下载实际 release.html_url | 真实系统打开 |
| S-053 | 关于页开源入口及实际条目数 | 生成 193 条目录 |
| S-054 | Windows UI/Core Rust/内核/社区四组；版本/用途/许可详情 | cargo Windows resolve 图 + 打包 notice 生成，待 UI |
| S-055 | 主页/许可链接、内嵌文本选择复制 | 已嵌入许可；部分源包无独立文本明确注明，待清理 |
| S-056 | 排序/显隐后 SaveHomeSections、Hub 数量 | 父任务构造恢复；备份包含顺序与隐藏 |
| D-001 | HUD 每次±2.2 pt、偏离时重置 | 更新 UI 原生菜单自动化断言 |
| D-002 | 校验/NumberBox 完整 11–44 范围 | 新增两个端点断言 |
| D-003 | 真正 Canvas App overlay + 内核二选一，下次开片固定；本地 XML/JSON 同样支持 | 实现调度、位置/暂停/seek、过滤/opacity/字号；渲染实机待验 |
| D-004 | 可选 anime-skip Client ID 安全保存、providers 使用 | 播放器 agent 消费 introHint |
| D-005 | coordinator 秒计时、状态变化停止 | 新增运行计时测试；HUD和选择页共用状态 |
| D-006 | 主查询与 Bangumi 别名并行；2s alias/5s总预算、合并去重 | 代码落地；别名 wire fixture 待补 |
| D-007 | 自动 danmaku.load 注入 aliases | 代码落地；别名 fixture 待补 |
| D-008 | Core canonicalMatchName 原版策略，不追加裸数字文件名 | 更新为精确规范串 + 裸数字回归断言 |
| D-009 | 季0 special、S/C/O回退，本地特殊关键词 | 新增季0 fallback与精确 SP2 断言 |

## 已执行验证（第二阶段）

- `dotnet build tests/OcPlayer.Integration/OcPlayer.Integration.csproj -c Debug -p:Platform=x64 --no-restore`：0 警告、0 错误。
- `reports/parity-settings-20261116-5` / `artifacts/settings-suite-5.log`：本范围新增的 HTTP / 持久化 / 恢复测试全部通过。完整 server suite 继续到 OAuth 旧用例时失败，已交集成负责人处理；不是把整套测试宣称通过。
- 已通过服务层验证的设置编号：S-002、S-018–S-021、S-023–S-026、S-029–S-032、S-033–S-034、S-037–S-040、S-042、S-045–S-046、S-048、S-051。这些包含真实本地 HTTP 请求与实际保存文件/Windows 凭据读写；相关按钮的视觉布局仍须 UI 检查。
- 字幕颜色/明确不加粗/最大边距、缓冲档位、默认关闭字幕及全部播放偏好的导出/预览/恢复已通过；其 native 效果由播放器负责人独立验收。
- D-002、D-005–D-009 通过真实 Core 验证。手动别名覆盖 Bangumi p1 搜索 `nameCN`、v0 详细 `body` envelope 的 infobox 别名及网关结果去重；自动回退使用共享 Core 分数阈值，未无条件挑第一条。
- 批量 TMDB 测试覆盖完成计数、新补/跳过/无匹配、取消后报告、下一次继续、各季获取、再次运行不重复抓成功结果。虚拟 `tmdb:n` 季不会复用其它季的分集，带简介/日期及未入库状态。
- S-055 已补所有已列组件的许可正文；Win2D 包的旧许可 URL 重定向到无关 Learn 页面，目录明确说明并随包保留官方源码 MIT 许可，避免将失效链接内容冒充许可证。

## 当前重要边界

- 所有设置均接实际存储/服务；播放 native、全局请求 UA、首页偏好恢复和启动更新的应用接线已完成。具体动态测试范围见收尾报告。
- 统一构建、完整真实媒体集成和设置/弹幕 UI 回归已完成，历史失败记录保留。
- App 层弹幕已通过真实 WinUI 暂停/seek/过滤/换片验收；各 GPU 画质模式和真实账号服务仍需专项实测。批量 TMDB 已通过本地 HTTP 端到端测试。
- 更新默认使用当前 Windows 仓库的 Gitea Release API，部署可用 `OCP_UPDATE_FEED` 指定另一实际 Windows 源。不会将 macOS Release 当作 Windows 更新。
