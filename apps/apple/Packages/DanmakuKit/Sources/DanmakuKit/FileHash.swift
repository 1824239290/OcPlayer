import CryptoKit
import Foundation

/// 弹弹play 匹配所需的文件指纹：前 16 MiB 的 MD5（32 位 hex 小写）。
/// 官方固定用前 16 MiB，不是前后各 16 MiB（PLAN.md 早期写法已修正）。
public enum FileHash {

    public static let headByteCount = 16 * 1024 * 1024

    /// 读取前 16 MiB 算 MD5。大文件流式读，不整段进内存。
    public static func head16MiBMD5(at url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw FileHashError.unreadable
        }
        defer { try? handle.close() }

        var hasher = Insecure.MD5()
        var remaining = headByteCount
        let chunk = 64 * 1024
        while remaining > 0 {
            try Task.checkCancellation()
            let toRead = min(chunk, remaining)
            let data: Data
            do {
                data = try handle.read(upToCount: toRead) ?? Data()
            } catch {
                throw FileHashError.readFailed
            }
            if data.isEmpty { break }
            hasher.update(data: data)
            remaining -= data.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 只取 HTTP 源的前 16 MiB 并哈希。
    ///
    /// ## `P2-38`：这里原先真的会把整部电影下载下来
    ///
    /// 旧实现是 `let (data, response) = try await session.data(for: request)` ——
    /// **`data(for:)` 会把整个响应体读完才返回**，而「服务器有没有老实按 Range 返回」
    /// 是在**之后**才校验的。于是服务器一忽略 `Range` 返回 `200 + 整个文件`，
    /// 就会先把整部电影（几 GB 到几十 GB）**读进内存**，然后才抛 `rangeUnsupported`。
    /// 旧注释写的 "this method can never download an entire movie"
    /// **在传输层根本不成立** —— 它只是「不会把整部电影拿来算哈希」。
    ///
    /// ## 现在的做法
    ///
    /// 用 `URLSessionDataDelegate` 驱动：**响应头一到就决策**（`didReceive response`），
    /// 不合格立刻 `completionHandler(.cancel)` —— 响应体一个字节都不会被消费。
    /// 合格才允许下传，并且累计量硬顶在 16 MiB + 1（超了就 cancel 并报 `readFailed`），
    /// 所以内存占用与流量都有**硬上限**，与服务器行不行善无关。
    ///
    /// 判定逻辑本身抽成纯函数 `RangePolicy.decide`，可表驱动测试。
    public static func head16MiBMD5(
        from url: URL,
        headers: [String: String] = [:],
        expectedFileSize: Int64? = nil,
        session: URLSession = DanmakuNetworking.makeSession()
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(headByteCount - 1)", forHTTPHeaderField: "Range")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (declaredRangeLength, data) = try await RangeBodyCollector.run(
            request: request,
            session: session,
            expectedFileSize: expectedFileSize
        )

        var hasher = Insecure.MD5()
        let received = data.count
        if !data.isEmpty { hasher.update(data: data) }

        if let declaredRangeLength {
            guard Int64(received) == declaredRangeLength else { throw FileHashError.readFailed }
        }
        if let expectedFileSize {
            let expected = min(Int64(headByteCount), max(expectedFileSize, 0))
            guard Int64(received) == expected else { throw FileHashError.readFailed }
        }
        guard received > 0 || expectedFileSize == 0 else { throw FileHashError.readFailed }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 「这个响应可不可以往下收」的判定（纯函数，`P2-38`）。
    ///
    /// 从 `head16MiBMD5(from:)` 里抽出来，既让 delegate 能在**收到响应头的同一时刻**
    /// 决策（不必等 body），也让这张表可以被穷举测试。
    enum RangePolicy {
        /// `.success(nil)` = 没有 `Content-Range`（`200` 且已知整文件 ≤ 16 MiB，无需声明长度）；
        /// `.success(len)` = 声明要收 `len` 字节。
        static func decide(
            statusCode: Int,
            contentRange: String?,
            expectedFileSize: Int64?
        ) -> Result<Int64?, FileHashError> {
            switch statusCode {
            case 206:
                guard let header = contentRange,
                      let range = ContentRange(header),
                      range.start == 0
                else { return .failure(.rangeUnsupported) }
                if let total = range.total {
                    guard expectedFileSize == nil || expectedFileSize == total else {
                        return .failure(.rangeUnsupported)
                    }
                    let expectedEnd = min(Int64(headByteCount), total) - 1
                    guard range.end == expectedEnd else { return .failure(.rangeUnsupported) }
                } else {
                    guard range.end == Int64(headByteCount - 1) else {
                        return .failure(.rangeUnsupported)
                    }
                }
                return .success(range.end - range.start + 1)
            case 200 where expectedFileSize.map({ $0 <= Int64(headByteCount) }) == true:
                // 服务器不认 Range，但整个文件本来就 ≤ 16 MiB —— 收下没问题。
                return .success(nil)
            case 200:
                // **危险分支**：服务器无视 Range，真要回整个文件。这里必须立刻拒绝，
                // 绝不能把 body 收下来（旧实现正是在这里先收完才判）。
                return .failure(.rangeUnsupported)
            default:
                return .failure(.httpStatus(statusCode))
            }
        }
    }

    /// 用 `URLSessionDataDelegate` 跑一次「只收前 16 MiB」的请求。
    ///
    /// 关键在 `didReceive response`：**响应头一到就判**，不合格立刻 `.cancel`。
    /// 这样 body 一个字节都不会进内存 —— 是 `P2-38` 的核心修法。
    ///
    /// 为什么不用 `session.bytes(for:)`：那是 `AsyncSequence<UInt8>`，
    /// 要按字节迭代 1600 万次异步跳（旧注释也记着这条路「慢几个数量级」）。
    /// 也不用 `data(for:)`：它读完整个 body 才返回。delegate 是唯一两者兼顾的路。
    private final class RangeBodyCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        /// 累计量的硬上限：比 16 MiB 多 1 字节即可判定「服务器发多了」。
        private static let bodyLimit = Int64(headByteCount) + 1

        private let expectedFileSize: Int64?
        private let lock = NSLock()
        private var data = Data()
        private var declaredRangeLength: Int64?
        private var failure: FileHashError?
        /// 父任务取消（不是网络失败），用于把错误映射成 `CancellationError`。
        private var cancelledByParent = false
        private var finished = false
        private var continuation: CheckedContinuation<(Int64?, Data), any Error>?

        init(expectedFileSize: Int64?) {
            self.expectedFileSize = expectedFileSize
        }

        /// 跑请求并把结果交回调用方。
        ///
        /// 从 `session.configuration` 另建一个带 delegate 的 session ——
        /// 注入进来的 session 不归我们管（生产里可能是共享实例），不能给它换 delegate。
        /// `configuration` 会带上 `protocolClasses`，所以测试的 mock 依然生效。
        static func run(
            request: URLRequest,
            session: URLSession,
            expectedFileSize: Int64?
        ) async throws -> (Int64?, Data) {
            let collector = RangeBodyCollector(expectedFileSize: expectedFileSize)
            let delegateSession = URLSession(
                configuration: session.configuration,
                delegate: collector,
                delegateQueue: nil
            )
            defer { delegateSession.invalidateAndCancel() }
            let task = delegateSession.dataTask(with: request)
            // **取消必须传到底层请求**（回归点）：
            // 旧实现用 `session.data(for:)`，它天然响应 `Task.cancel`；
            // 换成 delegate + `dataTask` 之后这层传递就断了 —— 父任务取消后
            // 会一直跑到下载结束（实测 3.08 s 才返回，期间白占带宽）。
            // 调用方 `DanmakuLoadOrchestrator.mediaHash` 是显式处理取消的
            // （`catch where CancellationClassifier.isCancellation`），
            // 传不下去那段代码就成了死码。
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    collector.attach(continuation)
                    task.resume()
                }
            } onCancel: {
                // `cancel()` 会触发 `didCompleteWithError(-999)`，collector 据此收尾。
                collector.cancelForParentTask()
                task.cancel()
            }
        }

        private func attach(_ continuation: CheckedContinuation<(Int64?, Data), any Error>) {
            lock.lock()
            // 极快的 mock 可能在 attach 之前就走完了整个回调序列。
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            if finished {
                // **取消也要在这里体现**（审查指出）：若 `didComplete` 抢在
                // `attach` 之前完成，父任务的取消会走到这个分支 ——
                // 直接返回 `(nil, empty)` 会把「被取消」当成「成功拿到空数据」，
                // 而 `expectedFileSize == 0` 时甚至会返回空文件的 MD5。
                let cancelledByParent = self.cancelledByParent
                let payload = (declaredRangeLength, data)
                lock.unlock()
                if cancelledByParent {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(returning: payload)
                }
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        // MARK: - URLSessionDataDelegate

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                record(.invalidResponse, task: dataTask, completionHandler: completionHandler)
                return
            }
            switch RangePolicy.decide(
                statusCode: http.statusCode,
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                expectedFileSize: expectedFileSize
            ) {
            case .success(let declared):
                lock.lock()
                declaredRangeLength = declared
                lock.unlock()
                completionHandler(.allow)
            case .failure(let error):
                record(error, task: dataTask, completionHandler: completionHandler)
            }
        }

        /// 父任务被取消（`withTaskCancellationHandler` 的 onCancel）。
        ///
        /// 记一个标记，让 `didCompleteWithError` 抛 `CancellationError` 而不是
        /// `readFailed` —— 调用方用 `CancellationClassifier` 区分「取消」与「故障」，
        /// 两者混在一起会让真正的失败被当成取消静默掉。
        func cancelForParentTask() {
            lock.lock()
            if failure == nil { cancelledByParent = true }
            lock.unlock()
        }

        /// 记录失败并让 URLSession 丢弃 body（`.cancel` 会中止下载）。
        private func record(
            _ error: FileHashError,
            task: URLSessionDataTask,
            completionHandler: (URLSession.ResponseDisposition) -> Void
        ) {
            lock.lock()
            failure = error
            lock.unlock()
            completionHandler(.cancel)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            lock.lock()
            if failure != nil || finished {
                lock.unlock()
                return
            }
            // 服务器发得比声明的多（或压根没声明又来势汹汹）：顶到上限就停。
            if Int64(self.data.count) + Int64(data.count) > Self.bodyLimit {
                failure = .readFailed
                lock.unlock()
                dataTask.cancel()
                return
            }
            self.data.append(data)
            lock.unlock()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let failure = self.failure
            // **必须在锁内读**（审查指出的真数据竞争）：`cancelForParentTask()`
            // 由 `withTaskCancellationHandler` 的 onCancel 在**另一条线程**上写，
            // 而在 `lock.unlock()` 之后读是无同步的并发访问 —— Swift 6 下是 UB，
            // 最坏会把「已完成」翻成「已取消」，或把取消读丢成 `readFailed`
            // （调用方会把后者当故障，而不是静默）。
            let cancelledByParent = self.cancelledByParent
            let payload = (declaredRangeLength, data)
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()

            guard let continuation else { return }
            if let failure {
                continuation.resume(throwing: failure)
            } else if cancelledByParent {
                continuation.resume(throwing: CancellationError())
            } else if error != nil {
                // 走到这里说明不是我们主动 cancel 的（那种情况 failure 已设）——
                // 网络层故障，对调用方就是「没读全」。
                continuation.resume(throwing: FileHashError.readFailed)
            } else {
                continuation.resume(returning: payload)
            }
        }
    }

    public enum FileHashError: Error, Equatable {
        case unreadable
        case readFailed
        case invalidResponse
        case rangeUnsupported
        case httpStatus(Int)
    }

    private struct ContentRange {
        let start: Int64
        let end: Int64
        let total: Int64?

        init?(_ value: String) {
            let fields = value.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }

            let rangeAndTotal = fields[1].split(
                separator: "/",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard rangeAndTotal.count == 2 else { return nil }
            let bounds = rangeAndTotal[0].split(
                separator: "-",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard bounds.count == 2,
                  let start = Self.parseNonnegativeInteger(bounds[0]),
                  let end = Self.parseNonnegativeInteger(bounds[1]),
                  start <= end,
                  end < Int64.max
            else { return nil }

            let total: Int64?
            if rangeAndTotal[1] == "*" {
                total = nil
            } else {
                guard let parsed = Self.parseNonnegativeInteger(rangeAndTotal[1]),
                      parsed > 0,
                      end < parsed
                else { return nil }
                total = parsed
            }

            self.start = start
            self.end = end
            self.total = total
        }

        private static func parseNonnegativeInteger(_ value: Substring) -> Int64? {
            guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
            return Int64(value)
        }
    }
}
