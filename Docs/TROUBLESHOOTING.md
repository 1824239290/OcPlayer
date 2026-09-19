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
