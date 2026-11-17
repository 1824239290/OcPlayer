import CoreModel
import Foundation
import JellyfinKit
import OcPlayerCore

/// Retained shared projections and refresh tickets. Swift keeps only task
/// handles and executes the native network/database effects.
struct RustMediaRepository: Sendable {
  let core: OcpCoreClient
  static func make(
    configuration: MediaRepository.Configuration, libraryPath: String? = nil,
    enabled: Bool = true
  ) -> Self? {
    guard enabled, libraryPath != nil || OcpCoreFeature.isEnabled else { return nil }
    do {
      let result = Self(core: try OcpCoreClient(libraryPath: libraryPath))
      let args =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
        as! [String: Any]
      _ = try result.command("open", args)
      return result
    } catch {
      report(error)
      return nil
    }
  }
  func command(_ method: String, _ args: [String: Any]) throws -> OcpResponse {
    let response = try core.call("mediaRepository." + method, arguments: args)
    guard response.ok else { throw OcpCoreError(message: response.message) }
    return response
  }
  func decode<T: Decodable>(_ method: String, _ args: [String: Any], as: T.Type = T.self) throws
    -> T
  {
    try command(method, args).decodeData(T.self)
  }
  static func report(_ error: any Error) {
    MetadataLog.logger.warning("Core 媒体仓储操作失败", fields: ["error": .string("\(error)")])
  }
  private struct Request<Key: Encodable, Value: Sendable & Encodable>: Encodable {
    let key: Key
    let entry: MemoryEntry<Value>?
    enum CodingKeys: String, CodingKey { case key, entry }
    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(key, forKey: .key)
      try c.encode(entry, forKey: .entry)
    }
  }
  private func arguments<Key: Encodable, Value: Sendable & Encodable>(
    bucket: String, key: Key, entry: MemoryEntry<Value>?
  ) throws -> [String: Any] {
    [
      "bucket": bucket,
      "payloadJSON": String(
        decoding: try JSONEncoder().encode(Request(key: key, entry: entry)), as: UTF8.self),
    ]
  }
  func get<Key: Encodable, Value: Sendable & Codable>(_ bucket: String, key: Key) -> MemoryEntry<
    Value
  >? {
    do {
      return try decode(
        "get", arguments(bucket: bucket, key: key, entry: Optional<MemoryEntry<Value>>.none))
    } catch {
      Self.report(error)
      return nil
    }
  }
  func put<Key: Encodable, Value: Sendable & Encodable>(
    _ bucket: String, key: Key, entry: MemoryEntry<Value>?
  ) {
    do { _ = try command("put", arguments(bucket: bucket, key: key, entry: entry)) } catch {
      Self.report(error)
    }
  }
  private struct Row<Key: Decodable, Value: Sendable & Decodable>: Decodable {
    let key: Key
    let entry: MemoryEntry<Value>
  }
  func all<Key: Hashable & Decodable, Value: Sendable & Codable>(_ bucket: String) -> [Key:
    MemoryEntry<Value>]
  {
    do {
      let rows: [Row<Key, Value>] = try decode("all", ["bucket": bucket])
      return rows.reduce(into: [:]) { $0[$1.key] = $1.entry }
    } catch {
      Self.report(error)
      return [:]
    }
  }
  func clear(_ bucket: String? = nil) {
    do {
      _ = try command(bucket == nil ? "clear" : "clearBucket", bucket.map { ["bucket": $0] } ?? [:])
    } catch { Self.report(error) }
  }
  static let missingTask = OcpCoreError(message: "Shared refresh ticket has no task")
  struct Claim: Decodable {
    let owner: Bool
    let ticket: UInt64
  }
  func claim<Key: Encodable>(_ kind: String, key: Key) throws -> Claim {
    try decode(
      "claim",
      [
        "kind": kind,
        "key": JSONSerialization.jsonObject(
          with: JSONEncoder().encode(key), options: [.fragmentsAllowed]),
      ])
  }
  func finish(_ claim: Claim) {
    do { _ = try command("finish", ["ticket": claim.ticket]) } catch { Self.report(error) }
  }
  private static let policyCore: OcpCoreClient? = {
    guard OcpCoreFeature.isEnabled else { return nil }
    return try? OcpCoreClient()
  }()
  static func freshness(
    _ kind: String, age: Double, ttl: Double, source: MediaDataSource? = nil,
    present: Bool? = nil
  ) -> Bool? {
    guard let policyCore else { return nil }
    do {
      var args: [String: Any] = ["kind": kind, "age": age, "ttl": ttl]
      args["source"] = source?.rawValue
      args["present"] = present
      let response = try policyCore.call("mediaRepository.freshness", arguments: args)
      guard response.ok else { throw OcpCoreError(message: response.message) }
      return try response.decodeData(Bool.self)
    } catch {
      report(error)
      return nil
    }
  }
}

extension MediaPageDescriptor: Codable {
  private enum CodingKeys: String, CodingKey {
    case parentID, kinds, recursive, sortField, ascending, watchState, searchTerm
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    var sort: MediaItemsSort?
    if let field = try c.decodeIfPresent(String.self, forKey: .sortField) {
      guard let value = MediaItemsSortField(rawValue: field) else {
        throw DecodingError.dataCorruptedError(
          forKey: .sortField, in: c, debugDescription: "Unknown sort field")
      }
      sort = .init(field: value, ascending: try c.decode(Bool.self, forKey: .ascending))
    }
    let state = try c.decodeIfPresent(String.self, forKey: .watchState)
    if let state, MediaItemsWatchState(rawValue: state) == nil {
      throw DecodingError.dataCorruptedError(
        forKey: .watchState, in: c, debugDescription: "Unknown watch state")
    }
    self.init(
      parentID: try c.decodeIfPresent(String.self, forKey: .parentID),
      kinds: try c.decodeIfPresent([MediaItem.Kind].self, forKey: .kinds),
      recursive: try c.decode(Bool.self, forKey: .recursive), sort: sort,
      watchState: state.flatMap(MediaItemsWatchState.init(rawValue:)),
      searchTerm: try c.decodeIfPresent(String.self, forKey: .searchTerm))
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(parentID, forKey: .parentID)
    try c.encodeIfPresent(kinds, forKey: .kinds)
    try c.encode(recursive, forKey: .recursive)
    try c.encodeIfPresent(sort?.field.rawValue, forKey: .sortField)
    try c.encodeIfPresent(sort?.ascending, forKey: .ascending)
    try c.encodeIfPresent(watchState?.rawValue, forKey: .watchState)
    try c.encodeIfPresent(searchTerm, forKey: .searchTerm)
  }
}
