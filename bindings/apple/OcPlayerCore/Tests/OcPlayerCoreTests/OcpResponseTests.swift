import Foundation
import XCTest
@testable import OcPlayerCore

@MainActor
final class OcpResponseTests: XCTestCase {
    func testTypedDataPreservesNestedIntegerRangesNullsAndFloatingFields() throws {
        struct Payload: Decodable {
            struct Nested: Decodable { let id: Int64; let value: Double; let enabled: Bool }
            let signed: [Int64]
            let unsigned: UInt64
            let nested: Nested
            let missing: Int?
        }
        let json = """
        {"ok":true,"code":0,"retryable":false,"message":"","data":{
         "signed":[9007199254740993,9223372036854775807,-9223372036854775808],
         "unsigned":18446744073709551615,"nested":{"id":9223372036854775806,"value":1.25,"enabled":true},"missing":null}}
        """
        let response = try OcpResponse.fromWire(Data(json.utf8))
        let result = try response.decodeData(Payload.self)
        XCTAssertEqual(result.signed, [9007199254740993, .max, .min])
        XCTAssertEqual(result.unsigned, .max)
        XCTAssertEqual(result.nested.id, .max - 1)
        XCTAssertEqual(result.nested.value, 1.25)
        XCTAssertTrue(result.nested.enabled)
        XCTAssertNil(result.missing)
        let projected = try JSONDecoder().decode(OcpResponse.self, from: Data("{\"ok\":true,\"code\":0,\"retryable\":false,\"message\":\"\",\"data\":[1,2]}".utf8))
        XCTAssertEqual(try projected.decodeData([Int].self), [1, 2])
    }

    func testPublicSyncAndAsyncCallsKeepExactPayloadAfterClientRetirement() async throws {
        let path = try OcpTestLibrary.path()
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", try XCTUnwrap(Bundle.module.url(forResource: "tmdb_wire_server", withExtension: "py", subdirectory: "Fixtures")).path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "http://127.0.0.1:\(port)"
        let args: [String: Any] = ["apiKey":"fixture", "apiBase":base + "/exact", "query":"作品", "mediaType":"movie", "year":Int.max]
        var client: OcpCoreClient? = try OcpCoreClient(libraryPath: path)
        let sync = try XCTUnwrap(client).call("tmdb.search", arguments: args)
        let async = try await XCTUnwrap(client).callAsync("tmdb.search", argumentsJSON: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
        client = nil
        struct Result: Decodable { let id: Int64 }
        XCTAssertTrue(sync.ok); XCTAssertTrue(async.ok)
        XCTAssertEqual(try sync.decodeData([Result].self).map(\.id), [.max, .max - 1])
        XCTAssertEqual(try async.decodeData([Result].self).map(\.id), [.max, .max - 1])
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/stats")!)
        struct Record: Decodable { let query: [String: [String]] }
        let records = try JSONDecoder().decode([Record].self, from: data)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.query["year"] == [String(Int.max)] })
    }
}
