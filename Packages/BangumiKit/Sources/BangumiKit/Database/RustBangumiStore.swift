import Foundation
import OcPlayerCore

/// Platform Codable boundary for the shared Bangumi.sqlite repository.
final class RustBangumiStore: Sendable {
  let core: OcpCoreClient
  init(path: String, libraryPath: String? = nil) throws {
    core = try OcpCoreClient(config: ["bangumiDatabasePath": path], libraryPath: libraryPath)
  }
  func call<T: Decodable>(_ method: String, _ args: [String: Any] = [:], as type: T.Type = T.self)
    throws -> T
  {
    let response = try core.call("bangumiStore.\(method)", arguments: args)
    guard response.ok else {
      throw NSError(
        domain: "OcPlayerCore.BangumiStore", code: Int(response.code),
        userInfo: [NSLocalizedDescriptionKey: response.message])
    }
    return try response.data.decode(type)
  }
  func write(_ method: String, _ args: [String: Any] = [:]) throws {
    let _: JSONValue = try call(method, args)
  }
  func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
  }
  func counts(_ method: String, _ args: [String: Any] = [:]) throws -> [Int: Int] {
    let raw: [String: Int] = try call(method, args)
    return Dictionary(
      uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
  }
  func subjects(_ ids: [Int]) throws -> [Int: BangumiSubjectDTO] {
    let subjects: [BangumiSubjectDTO] = try call("subjects", ["ids": ids])
    return Dictionary(uniqueKeysWithValues: subjects.map { ($0.id, $0) })
  }
}
