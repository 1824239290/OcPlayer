import Foundation

/// Core writes bounded diagnostic exports to a caller-owned new file. Large
/// log/trace contents never round-trip through the JSON response envelope.
public final class OcpDiagnosticExport: @unchecked Sendable {
    public struct Trace: Sendable {
        public let url: URL
        public let name: String
        public let maxBytes: Int
        public init(url: URL, name: String, maxBytes: Int) {
            self.url = url; self.name = name; self.maxBytes = maxBytes
        }
    }
    public struct TraceReport: Decodable, Sendable {
        public let name: String
        public let bytes: Int
        public let truncated: Bool
    }
    public struct Report: Decodable, Sendable {
        public let path: String
        public let bytes: UInt64
        public let skippedLogFiles: [String]
        public let traces: [TraceReport]
    }
    private let client: OcpCoreClient
    public init?(client: OcpCoreClient? = nil, libraryPath: String? = nil) {
        guard OcpCoreFeature.isEnabled else { return nil }
        do {
            self.client = try client ?? OcpCoreClient(libraryPath: libraryPath)
            let response = try self.client.call("diag.exportFile.capabilities")
            guard response.ok else { return nil }
        } catch { return nil }
    }
    public func export(logDirectory: URL, to output: URL, headerLines: [String],
                       bodyByteBudget: Int?, traces: [Trace], username: String) throws -> Report {
        guard logDirectory.isFileURL, output.isFileURL, traces.allSatisfy({ $0.url.isFileURL }) else {
            throw OcpCoreError(message: "Diagnostic export requires file URLs")
        }
        let response = try client.call("diag.exportFile", arguments: [
            "logDirectory": logDirectory.path, "outputPath": output.path,
            "headerLines": headerLines, "bodyByteBudget": bodyByteBudget as Any,
            "traces": traces.map { ["path": $0.url.path, "name": $0.name, "maxBytes": $0.maxBytes] as [String: Any] },
            "username": username,
        ])
        guard response.ok else { throw OcpCoreError(message: response.message) }
        return try response.decodeData(Report.self)
    }
}
