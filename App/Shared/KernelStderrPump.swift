import DiagnosticsKit
import Foundation

/// 把内核（Rust + FFmpeg）的 stderr 接进诊断管线。
///
/// 背景：GUI 启动时进程的 fd 2 归 launchd，内核往 stderr 写的东西（`ErikaHDR`、
/// FFmpeg 的告警）在 App 侧完全看不到——issue #1/#2 排障时内核侧证据缺失就是这一块。
/// 这里把 fd 2 换成管道写端，后台线程逐行读、按前缀分类后写进 `diagnostics.jsonl`。
///
/// 边界与代价：
/// - **全局副作用**：同进程里任何往 stderr 写的东西都会经过这里（Swift 运行时告警、
///   第三方库）。原 stderr 留了一份 fd，转发时 tee 回去，所以终端 / Console.app 的
///   行为不变、崩溃栈照样看得见；
/// - 按 `\n` 切帧，不完整的尾字节留到下一块（见 `KernelStderrDecoder`）；
/// - 限速由 decoder 负责，超预算的行丢弃并定期汇总一条。
final class KernelStderrPump: @unchecked Sendable {
    static let shared = KernelStderrPump()

    private let queue = DispatchQueue(label: "dev.jumusu.OcPlayer.kernel-stderr", qos: .utility)
    private let lock = NSLock()
    private var started = false
    private var loggers: [String: DiagnosticLogger] = [:]

    /// 抢在第一次内核调用之前启动（`OcPlayerApp.init`）。重复调用无副作用。
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }

        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return }
        let readFD = fds[0]
        let writeFD = fds[1]
        // 留一份原 stderr：转发时 tee 回去（终端 / Console.app 行为不变）。
        let originalStderr = dup(STDERR_FILENO)

        guard dup2(writeFD, STDERR_FILENO) >= 0 else {
            close(readFD)
            close(writeFD)
            if originalStderr >= 0 { close(originalStderr) }
            return
        }
        close(writeFD)
        started = true
        queue.async { [weak self] in
            self?.pump(readFD: readFD, teeFD: originalStderr)
        }
    }

    /// 读端循环：阻塞在 `read` 上直到写端关闭（进程退出）或出错。
    private func pump(readFD: Int32, teeFD: Int32) {
        var decoder = KernelStderrDecoder()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var lastSummaryAt = Date()
        while true {
            let count = read(readFD, &buffer, buffer.count)
            if count <= 0 { break }
            for line in decoder.ingest(Data(buffer[0..<count])) {
                record(line)
                tee(line.text, to: teeFD)
            }
            if Date().timeIntervalSince(lastSummaryAt) >= 1 {
                lastSummaryAt = Date()
                if let dropped = decoder.takeDroppedSummary(), dropped > 0 {
                    logger(for: "Erika/Stderr").warning("内核 stderr 限速丢弃 \(dropped) 行")
                }
            }
        }
    }

    private func record(_ line: KernelStderrDecoder.Line) {
        logger(for: line.category).log(level: line.level, "\(line.text)")
    }

    /// 原样写回原 stderr：拦截归拦截，不该把终端/Console 的输出吞掉。
    private func tee(_ text: String, to fd: Int32) {
        guard fd >= 0 else { return }
        var data = Data((text + "\n").utf8)
        data.withUnsafeMutableBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
    }

    /// 按 category 缓存 logger（同一 category 复用同一实例，与 NetworkLog 的做法一致）。
    private func logger(for category: String) -> DiagnosticLogger {
        lock.lock()
        defer { lock.unlock() }
        if let existing = loggers[category] { return existing }
        let logger = DiagnosticLogger(category: category)
        loggers[category] = logger
        return logger
    }
}
