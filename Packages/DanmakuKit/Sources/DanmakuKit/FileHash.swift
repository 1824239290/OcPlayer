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

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FileHashError.invalidResponse
        }
        switch http.statusCode {
        case 206:
            guard http.value(forHTTPHeaderField: "Content-Range")?
                .lowercased().hasPrefix("bytes 0-") == true else {
                throw FileHashError.rangeUnsupported
            }
        case 200 where expectedFileSize.map({ $0 <= Int64(headByteCount) }) == true:
            break
        case 200:
            throw FileHashError.rangeUnsupported
        default:
            throw FileHashError.httpStatus(http.statusCode)
        }

        var hasher = Insecure.MD5()
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var received = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            received += 1
            if buffer.count == 64 * 1024 {
                hasher.update(data: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            if received == headByteCount { break }
        }
        if !buffer.isEmpty { hasher.update(data: buffer) }

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
}
