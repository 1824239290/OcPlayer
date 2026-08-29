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

    /// Fetches and hashes at most the first 16 MiB of an authenticated HTTP source.
    /// A server that ignores Range is accepted only when the complete file is known
    /// to fit inside the limit, so this method can never download an entire movie.
    public static func head16MiBMD5(
        from url: URL,
        headers: [String: String] = [:],
        expectedFileSize: Int64? = nil,
        session: URLSession = .shared
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(headByteCount - 1)", forHTTPHeaderField: "Range")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FileHashError.invalidResponse
        }
        let declaredRangeLength: Int64?
        switch http.statusCode {
        case 206:
            guard let header = http.value(forHTTPHeaderField: "Content-Range"),
                  let range = ContentRange(header),
                  range.start == 0
            else {
                throw FileHashError.rangeUnsupported
            }
            if let total = range.total {
                guard expectedFileSize == nil || expectedFileSize == total else {
                    throw FileHashError.rangeUnsupported
                }
                let expectedEnd = min(Int64(headByteCount), total) - 1
                guard range.end == expectedEnd else {
                    throw FileHashError.rangeUnsupported
                }
            } else {
                guard range.end == Int64(headByteCount - 1) else {
                    throw FileHashError.rangeUnsupported
                }
            }
            declaredRangeLength = range.end - range.start + 1
        case 200 where expectedFileSize.map({ $0 <= Int64(headByteCount) }) == true:
            declaredRangeLength = nil
            break
        case 200:
            throw FileHashError.rangeUnsupported
        default:
            throw FileHashError.httpStatus(http.statusCode)
        }

        // Range 校验已保证响应体 ≤ 16 MiB，一次拿全再喂哈希。原先逐字节迭代
        // AsyncBytes（16 MiB = 1600 万次异步跳 + 逐字节 append），慢几个数量级。
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
