import DiagnosticsKit
import Foundation

/// 内核 stderr 的分帧、分类与限速。**纯逻辑**，单独拆出来单测——真正的 fd 重定向
/// 是进程级副作用，没法在单元测试里跑。
///
/// 分帧规则：按 `\n` 切，最后一段不完整的字节留在 `remainder` 里等下一块（内核是
/// 逐行 `eprintln!`，但管道读到的块边界与行边界无关）。超长行按 `maxLineBytes`
/// 截断：内核偶尔 dump 一大段 JSON，一条记录不该顶掉整个文件的配额。
struct KernelStderrDecoder {

    /// 一条该转发给诊断管线的内核输出。
    struct Line: Equatable {
        let category: String
        let level: DiagnosticLevel
        let text: String
    }

    private var remainder = Data()
    private var windowStart: Date
    private var forwardedInWindow = 0
    /// 本窗口被限速丢掉的行数（攒到窗口末尾由调用方补一条汇总）。
    private(set) var droppedInWindow = 0
    /// 被丢掉的 trace 回声行数（诊断用：说明 trace 数据在 trace 文件里，不在本管线）。
    private(set) var traceEchoesDropped = 0

    let linesPerSecondBudget: Int
    let maxLineBytes: Int

    init(linesPerSecondBudget: Int = 200, maxLineBytes: Int = 4096, now: Date = Date()) {
        self.linesPerSecondBudget = linesPerSecondBudget
        self.maxLineBytes = maxLineBytes
        self.windowStart = now
    }

    /// 吃一块字节，返回该转发的行（已限速、已截断）。
    /// 超过预算的行直接丢：内核出问题时会把 stderr 刷爆，反压内核线程比丢日志更糟。
    mutating func ingest(_ chunk: Data, now: Date = Date()) -> [Line] {
        remainder.append(chunk)
        var out: [Line] = []
        while let newline = remainder.firstIndex(of: 0x0A) {
            let raw = remainder[remainder.startIndex..<newline]
            remainder = remainder[remainder.index(after: newline)...]
            guard let line = decode(raw, now: now) else { continue }
            out.append(line)
        }
        // 残行也可能超长（对端一直不换行）：就地截断，别让它无限涨。
        if remainder.count > maxLineBytes {
            remainder = remainder.prefix(maxLineBytes)
        }
        // `remainder[a...]` 是共享底层存储的切片：已消费前缀留在存储里，下次 append 沿偏移
        // realloc 时把它们一并保住，缓冲随累计 stderr 无限涨（实测一条会话残留 60MB+）。
        // 消费完把残行拷到全新右尺寸存储，让旧存储随切片离开被释放。残行 ≤ maxLineBytes，拷贝可忽略。
        remainder = Data(remainder)
        return out
    }

    /// 窗口末尾该不该补一条「被限速丢了多少行」的汇总。
    mutating func takeDroppedSummary(now: Date = Date()) -> Int? {
        rollWindowIfNeeded(now: now)
        guard droppedInWindow > 0 else { return nil }
        let count = droppedInWindow
        droppedInWindow = 0
        return count
    }

    /// 内核 trace 的 stderr 回声（`[erika-*-trace] …`）：同样的内容已经落在
    /// `erika_playback_trace.jsonl` / `erika_http_trace.jsonl` 里，再抄一份进
    /// diagnostics.jsonl 只会把文件冲掉——实测逐帧 trace（playback/clock/render/
    /// presenter/audio/capi 六族）合计 200+ 行/秒，16 秒就把 2MB 的轮转窗口填满，
    /// 还把 App 自己的记录挤出窗口。所以回声一律丢，trace 数据只从 trace 文件读。
    static func isTraceEcho(_ line: String) -> Bool {
        guard line.hasPrefix("[erika-"), let close = line.firstIndex(of: "]") else { return false }
        return line[line.index(after: line.startIndex)..<close].hasSuffix("-trace")
    }

    private mutating func decode(_ raw: Data, now: Date) -> Line? {
        var bytes = raw
        var truncated = false
        if bytes.count > maxLineBytes {
            bytes = bytes.prefix(maxLineBytes)
            truncated = true
        }
        let text = String(decoding: bytes, as: UTF8.self)
        // trace 回声在限速之前就丢：它们不该占用真日志的预算。
        guard !Self.isTraceEcho(text) else {
            traceEchoesDropped += 1
            return nil
        }
        rollWindowIfNeeded(now: now)
        forwardedInWindow += 1
        guard forwardedInWindow <= linesPerSecondBudget else {
            droppedInWindow += 1
            return nil
        }
        return Line(
            category: Self.category(for: text),
            level: Self.level(for: text),
            text: truncated ? text + " […截断]" : text
        )
    }

    private mutating func rollWindowIfNeeded(now: Date) {
        guard now.timeIntervalSince(windowStart) >= 1 else { return }
        windowStart = now
        forwardedInWindow = 0
    }

    // MARK: - 分类

    /// 前缀 → category。已知前缀来自内核产物里的字符串（`ErikaHDR` / `ErikaOpenOptions`），
    /// 其余统一进 `Erika/Stderr`——分类只为过滤方便，不认识不该丢。
    static func category(for line: String) -> String {
        if line.hasPrefix("ErikaHDR") { return "Erika/Output" }
        if line.hasPrefix("ErikaOpenOptions") { return "Erika/Open" }
        return "Erika/Stderr"
    }

    /// 级别：内核 stderr 默认进 debug（详细档才看），但带错误特征的行要能在默认档
    /// 看得见——否则「内核报错了」这件事仍然只存在于丢失的 stderr 里。
    static func level(for line: String) -> DiagnosticLevel {
        let lowered = line.lowercased()
        if lowered.contains("panic") || lowered.contains("fatal") { return .error }
        if lowered.contains("error") || lowered.contains("failed") || lowered.contains("rejected") {
            return .warning
        }
        return .debug
    }
}
