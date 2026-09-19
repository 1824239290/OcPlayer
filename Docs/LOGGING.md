# 日志与诊断

一份参考：日志长什么样、级别怎么定、写代码时该往哪记、出问题时怎么把证据取出来。
排障流程见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。

## 管线长什么样

```
各模块（App / Playback / ErikaKit / JellyfinKit / …）
      └─ PlaybackLog · AppDiagnostics · BangumiDiagnostics · NetworkLog   ← 薄包装，@autoclosure
            └─ DiagnosticsKit.DiagnosticLogger                            ← 唯一底层，按 category 复用同一 backend
                  ├─ OSLog（subsystem dev.jumusu.OcPlayer，Console.app 可按 category 过滤）
                  └─ JSONL 文件（下面这份才是排障主场）
```

- **消息一律 `@autoclosure`**：低于当前档位时整条不求值（字符串插值都不做）。
- **过滤发生在最前面**：判级别 → 判节流 → 求值 + 脱敏 → 落两个出口。被级别压掉的记录
  不会污染节流计数。
- **写盘异步串行 + `O_APPEND`**：跨进程共写（App 与测试宿主、双开实例）也不会把记录撕碎。

## 文件

| 项 | 值 |
|---|---|
| 目录 | macOS `~/Library/Logs/OcPlayer/`；iOS 沙盒 `Library/Logs/OcPlayer` |
| 命名 | `diagnostics-<yyyyMMdd-HHmmss>-<会话id>.jsonl`，**一次启动一个**；写满续编 `-2`、`-3` |
| 保留 | 最新 10 个文件、总量 ≤50MB、不超过 30 天；**当前会话文件永不删**（宁可短时超限） |
| 内核 trace | `erika_http_trace.jsonl`、`erika_playback_trace.jsonl`（只在「详细日志」档生成，按会话清理） |

会话文件的意义：报障时只需要交「发生问题那次启动的那个文件」，不用跨会话猜哪几行是这次的。

## 级别

| 级别 | 语义 | 典型 |
|---|---|---|
| `debug` | 高频细节，排障时才看 | 守卫拒绝、中间态、重试尝试、逐帧采样 |
| `info` | 状态迁移 / 一次操作的结果 / 用户可见决策 | open 起止、跳过动作、内核装配、装载结果 |
| `notice` | 行为改变但可自愈，值得留痕 | （暂未使用） |
| `warning` | 功能受影响但继续 | 加载失败、上报失败、内核控制调用失败、卡死检测 |
| `error` | 功能中断 | open 失败、内核错误事件、渲染失败 |
| `critical` | 进程级危险 | 日志系统自身故障 |

**默认档是 `info`**——所以「一次操作一条结果」的日志必须定成 `info`，否则它在默认档里
看不见。守卫与中间态留 `debug`，只在「详细日志」档出现。

## 两个档位（设置 → 维护）

| | 关（默认） | 开（详细日志） |
|---|---|---|
| 最低落盘级别 | `info` | `debug` |
| 内核开关 | 全清 | `ERIKA_HTTP_TRACE(_FILE)` / `ERIKA_PLAYBACK_TRACE(_FILE)` / `ERIKA_HDR_DEBUG` |
| 生效时机 | 立即 | **下一次播放**（内核在引擎创建时读环境变量） |

刻意**没有**放进「详细日志」的内核开关（体量太大，会把诊断文件冲掉，需要时手动加）：
`ERIKA_FFMPEG_DEBUG`（1500+ 行/秒）、`ERIKA_SUBTITLE_DIAG`（约 100 行/秒）。
手动用法：`ERIKA_SUBTITLE_DIAG=1 /path/to/OcPlayer.app/Contents/MacOS/OcPlayer`。

## 模块矩阵（category → 谁在写 → 默认档能看到什么）

| category | 来源 | 默认档内容 |
|---|---|---|
| `App` | App 顶层（启动、存储维护、AppModel 决策、玩家页面边界） | 启动记录、播放准备/收尾、跳看决策 |
| `Playback` | PlayerState / PlaybackController（含事件行） | 播放事件全程（见下）、open 结果、错误事件 |
| `Erika` / `Erika/Open` / `Erika/Output` / `Erika/Stderr` | 内核适配器 + 内核 stderr 泵 | 引擎生命周期（info）与内核报错（warning+）；其余细节在详细档 |
| `Jellyfin` | JellyfinKit（请求结果、进度上报） | 请求成功（含耗时）、失败、上报异常 |
| `Bangumi` | BangumiKit + App 层 Bangumi 页面 | 自动标看过的决策与跳过原因、加载/标记失败（warning） |
| `MoviePilot` | MoviePilotKit | 登录/刷新结果、SSE 搜索成功 |
| `Danmaku` | DanmakuKit 网关/编排/overlay | 匹配与装载结果、爆发告警；逐帧细节受「弹幕诊断日志」开关控制 |
| `AniList` / `AniSkip` | 片头数据源 | 降级原因、失败 |
| `Image` | AppDesignKit 图片管道 | 加载失败（5s 节流） |

## 播放事件行（排障骨架）

`PlaybackLog.event(_:fields:)`，message 固定 `播放事件 <name>`，字段必带 `event=<name>`：

| 事件 | 关键字段 |
|---|---|
| `open.start` | `source`(network/local)、`read_ahead_bytes`、`back_buffer_bytes`（回退预算，null = 内核默认 16 MiB）、`has_resume` |
| `open.done` | `ok`、`elapsed_ms`、失败时 `error` |
| `first_frame` | `position_ms`（宿主近似点：状态进 playing；内核没有独立首帧事件） |
| `buffer.start` / `buffer.end` | `position_ms`；结束带 `duration_ms`（这轮缓冲多久） |
| `stall` | `recovered`、`frozen_ms`、`position_ms`（在播且内核没报缓冲、位置却不动） |
| `seek` | `from_ms`、`to_ms`、`kind`(scrub/skip/chapter/auto/resume) |
| `error` | `code`、`message`（内核原文）、`position_ms` |
| `session.end` | `reason`(user/superseded)、`played_ms`、`buffer_count`、`buffered_ms`、`error_count`、`stall_count` |

每条记录还带 `session`（进程级 8 位 id）与 `sequence`（进程内递增），时间戳精确到毫秒——
按 `session` 过滤即得「一次启动的完整时间线」，按时间排即可判先后（例如续播 seek 与弹幕注入谁先）。

```json
{"category":"Playback","fields":{"elapsed_ms":694,"event":"open.done","ok":true},"level":"info",
 "message":"播放事件 open.done","sequence":42,"session":"6e0ae557",
 "subsystem":"dev.jumusu.OcPlayer","timestamp":"2026-09-15T05:02:43.220Z"}
```

## 内核日志（stderr 泵）

GUI 启动时进程 fd 2 归 launchd，内核往 stderr 写的东西没人接。App 启动早期把 fd 2 换成
管道，后台线程逐行读、按前缀分类后写进同一份 JSONL（原 stderr 留了一份 fd 做 tee，
终端 / Console.app 行为不变）：

- `ErikaHDR…` → `Erika/Output`（HDR / 输出模式决策）
- `ErikaOpenOptions…` → `Erika/Open`
- 其余 → `Erika/Stderr`（内核结构化事件、Rust panic、ffmpeg 输出）
- 带 `error`/`failed`/`rejected` 的行提到 `warning`，`panic`/`fatal` 提到 `error`——内核报错
  在默认档就能看见
- `[erika-*-trace] …` 的 trace 回声**不入管线**（内容已在 trace 文件里），200 行/秒限速兜底

## 不记什么

- **凭据**：token / Authorization / Cookie / 密码一律不主动记录；写盘前还会过一遍脱敏器
  （`Bearer/Basic` 值、`token=`／`password=` 类赋值、JWT、URL userinfo 与 query、用户路径）。
- **请求日志只记 path**，不记 query 与请求体（`NetworkLog.logPath`）。
- 已知会入盘的（内网自用可接受）：媒体标题 / 文件名、服务器地址、图片 URL（query 会脱敏）。
  导出诊断包时会把这些说明一并写进文件头部。

## 导出诊断包

设置 → 维护 → 「导出诊断包…」：头部（版本 / 构建 / commit / 平台 / 系统 / 当前档位 /
脱敏说明）+ 全部保留记录 + 内核 trace 文件，产出**单个 `.txt`**（`OcPlayer-诊断-<时间戳>.txt`）。
单文件而非 zip：iOS 起不了 `ditto` 进程，双端行为一致，issue 里能直接附件。

## 改代码时

1. **选级别**：按上表语义，别按「我觉得重不重要」。一次操作的结果 → `info`。
2. **新事件**：加进 `PlaybackEvent` 并更新本文件的事件表（字段用 snake_case，时间类字段
   `*_ms` 一律毫秒整数）。
3. **高频日志**：先想能不能「变化才记」，其次用 `DiagnosticThrottle`，别直接打。
4. **测试**：`DiagnosticsKit` 覆盖管线语义（级别过滤 / 节流 / 会话文件 / 导出），
   业务侧只钉关键行为，不逐条断言日志文本。
