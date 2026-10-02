# 排障手册（日志）

配合 [LOGGING.md](LOGGING.md)（字段与级别口径）使用。这份只讲流程：出问题 → 看哪几行 → 怎么定位。
下面命令里的 `$L` 都是「最近一次启动的日志文件」：

```bash
L=$(ls -t ~/Library/Logs/OcPlayer/diagnostics-*.jsonl | head -1)
```

## 30 秒上手（替用户取证据）

1. 设置 → 维护 → 打开「**详细日志**」（内核 trace 下一次播放生效）
2. 让用户复现一次问题
3. 设置 → 维护 → 「**导出诊断包…**」，把导出的 `.txt` 收过来

诊断包 = 头部（版本/commit/平台/档位/脱敏说明）+ 全部保留记录 + 内核 trace，一个文件说明一切。

## 症状 → 看哪几行

### 播到一半停住 / 再也不动（issue #1 类）

```bash
grep -h -E '"event":"(stall|error|open.done|session.end)"|内核 stderr' $L | tail -30
grep -h '"stall"' $L | jq -c '{t:.timestamp, f:.fields}'      # 卡死：frozen_ms 是冻了多久
grep -h '"error"' $L | jq -c '{t:.timestamp, f:.fields}'      # 内核错误：code/message 原文
```

看点：
- `stall`（`recovered=false`）说明「在播、内核没报缓冲、位置却停住」——真卡死，不是等数据
- `error.message` 是内核原文（如读失败的具体错误串）；`session.end` 的 `stall_count/error_count`
  一眼看出这次播放一共卡了几回
- 网络类还要看 `buffer.*`：有 buffer 说明是饿数据，没有才是内核侧断了

### iOS 切后台回来后报错 / 没有接着播

```bash
grep -h -E "系统进后台|系统回前台|后台往返后自动重建播放" $L | tail -20
```

看点：
- 只有带这三行的包是新行为。旧包在 iOS 上切后台不做处理，内核的音频出口（AudioQueue）
  与 VideoToolbox 解码会话撑不过挂起，回前台第一包数据就报
  `ffmpeg error … avcodec_send_packet: Unknown error occurred (-1313558101)`，只能手动点重试。
- 「系统进后台：暂停在播会话」= App 在进程被挂起**之前**拦住了。离开前没在播就没有这一行，
  属预期：用户自己按的暂停不该被系统接回去。
- 回来要么「系统回前台：接着播」（内核算健康，原地解开暂停），要么
  「后台往返后自动重建播放」（内核没撑过挂起，按「重试」那条路静默重建）。后者的 `reason`
  区分：`foreground`（回来时已经 `.error`）、`post-resume`（`play()` 之后才炸，3 秒观察窗接住的）、
  `resume-failed`（`play()` 都没调成）。
- 自动重建只做一次：紧接着还有 `内核错误事件` 就是真失败，落回普通错误徽章，不循环重试。

### 画面周期性变暗/闪（issue #2 类）

```bash
grep -h '"event":"buffer' $L | jq -c '{t:.timestamp, e:.fields.event, ms:.fields.duration_ms}'
grep -h 'output_mode\|outputModeSwitches\|ErikaHDR' $L | tail -20
```

看点：
- `buffer.start/end` 成对出现的**频率**——若与用户描述的「每 30 秒一次」吻合，就是缓冲周期在驱动 UI
- `output_mode_switches` 变化 / `ErikaHDR: … output mode=…` 行说明显示器侧真的切了输出模式
  （HDR/刷新率重配），那是另一路成因

### 一直转圈 / 打不开

```bash
grep -h '"event":"open' $L | jq -c '{t:.timestamp, e:.fields.event, ms:.fields.elapsed_ms, ok:.fields.ok, err:.fields.error}'
```

看点：`open.done ok=false` 的 `error` 是直接原因；`elapsed_ms` 很大（几秒以上）说明卡在连接/探测，
配合 `read_ahead_bytes` / `back_buffer_bytes` 与 `source` 判断是不是弱网 + 预读窗口过大。

### 界面未响应 / 点一下按钮就永久卡死（只能强退）

**卡住时别强退**，当场抓栈（`sample` 对 Debug 包与正式包都可用；采样那几秒界面会更卡，正常）：

```bash
sample OcPlayer 5 -f /tmp/ocplayer-hang.txt
grep -n -B2 -A2 "psynch_mutexwait" /tmp/ocplayer-hang.txt   # 互等锁的两条链
```

看点：

- **「永久卡死、只能强退」几乎总是互等锁（ABBA 死锁），不是性能问题**：两条线程各持着对方
  要的锁。`sample` 里两条链的顶端都会停在 `__psynch_mutexwait`——把每条链的**上一帧**读出来，
  就是「谁持有什么、谁在等什么」，环一眼可见。别去猜渲染慢。
- 2026-10-02「设置 → 退出 MoviePilot」实录：主线程停在 `SettingsView.body` 读
  `MoviePilotStore.serverURLString` 的 `NSLock` 上，后台 actor 线程停在
  `MoviePilotStore.clearSession()` → `defaults.removeObject` → SwiftUI `Update.begin()` 上。
  根因是**后台线程写 `UserDefaults`**：SwiftUI 给 `@AppStorage` 挂的观察者在**发通知的线程**上
  申请 UI 更新锁（`MovableLock`），而主线程正持着那把锁等 store 的锁。已由
  `MoviePilotStore.mutateDefaults(_:)` 兜住——同类新代码**不要**在后台线程写 `UserDefaults`。
- 线索组合很好认：**两端都复现** + **只有某一个按钮必卡** + 与网络/数据量无关，优先怀疑
  「共享代码 + 特定线程路径」，而不是某端的渲染。
- 只要日志在卡死前正常写盘，就说明存储动作已完成、卡的是它之后的 UI 更新那一段（本例即如此：
  重启后登录态确实已是退出状态）。

### 卡顿、缓冲频繁

```bash
grep -h '"event":"buffer.start"' $L | wc -l          # 缓冲次数
grep -h '"event":"buffer.end"' $L | jq '[.fields.duration_ms] | add / 1000'   # 总缓冲秒数
grep -h 'readAhead' $L | tail -3                     # 实际生效的预读窗口 / 回退预算
```

### 弹幕不出来 / 时间轴错

先开「弹幕诊断日志」（设置 → 维护），它会带来对齐点与爆发记录：

```bash
grep -h '"category":"Danmaku"' $L | tail -30
grep -h '弹幕时间轴对齐\|弹幕爆发\|弹幕 overlay 状态' $L | tail -20
```

看点：`弹幕时间轴对齐` 的 `pointer/total` 与 `mediaTime`、`弹幕爆发` 的 `spawned` 值。

### 内存涨 / 播放结束后占用高

```bash
grep -h '内核内存' $L | jq -c '{t:.timestamp, msg:.message}' | tail -20
```

open/stop 各一条基线，播放中只在「有实质变化」时记（关键分项变化 ≥8MiB 或 ≥10%）。
比 open 与 stop 两条基线的差值即可判断这段播放有没有泄漏。

### Bangumi / MoviePilot 联动没反应

```bash
grep -h '"category":"Bangumi"\|"category":"MoviePilot"' $L | tail -20
```

自动标看过的**决策**也在里面（「未标记：条目未关联 / 集号匹配不上 / 本集已是看过」），
失败是 `warning`。

## 无法复现 / 用户只给一句话

按顺序做：

1. 让用户开「详细日志」（设置 → 维护）
2. 复现 → 立刻导出诊断包（不要重启后再导，会话文件按启动切分，但导出会把保留的全部带上）
3. 如果问题与显示器/输出有关，顺便记一下当时是在哪个屏、有没有切 HDR/刷新率

## 提交 issue 时建议附上

- 诊断包 `.txt`（一键导出）
- 问题发生的**时间点**（诊断包头部有时间，记录带毫秒时间戳）
- 当时的操作（打开什么、卡在哪一步）

## 自己动手验证时

- 只想看事件骨架：`grep -h '"event"' $L | jq -c '{t:.timestamp, e:.fields.event}'`
- 只看某一次启动：`grep -h '"session":"<8位id>"' ~/Library/Logs/OcPlayer/diagnostics-*.jsonl`
- 自检通道（无需手点）：见 `build-verify-recipes` 里的 `OCPLAYER_SELFTEST_*` 用法——
  能脚本化播放/暂停/seek/倍速/resize，跑完自己退出；**它只吃本地文件**，所以不会产生
  `buffer` 事件（本地不缓冲），也没有 `session.end`（收尾是 `exit(0)`）。
