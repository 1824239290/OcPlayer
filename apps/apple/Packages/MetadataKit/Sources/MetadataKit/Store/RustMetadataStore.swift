import CoreModel
import Foundation
import JellyfinKit
import OcPlayerCore

/// Maps platform Codable payloads to the shared SQLite cache. Core owns SQL,
/// transactions, progress reconciliation and maintenance; malformed/unknown
/// cache payloads remain misses at the platform decoding boundary.
final class RustMetadataStore: Sendable {
  let client: OcpCoreClient

  init(path: String, libraryPath: String? = nil) throws {
    client = try OcpCoreClient(config: ["mediaDatabasePath": path], libraryPath: libraryPath)
  }

  func call(_ method: String, _ args: [String: Any] = [:]) throws -> RustCacheResponse {
    let response = try client.call("cache.\(method)", arguments: args)
    guard response.ok else {
      throw NSError(
        domain: "OcPlayerCore.Cache", code: Int(response.code),
        userInfo: [NSLocalizedDescriptionKey: response.message])
    }
    return RustCacheResponse(response: response)
  }

  func write(_ method: String, _ args: [String: Any] = [:]) throws {
    _ = try call(method, args)
  }

  func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
  }

  func args(_ tenant: TenantID, now: Date? = nil) -> [String: Any] {
    var args: [String: Any] = ["tenantId": tenant.rawValue]
    if let now { args["now"] = now.timeIntervalSince1970 }
    return args
  }

  func key(_ key: PageKey) -> [String: Any] {
    [
      "parentID": key.parentID, "kinds": key.kinds, "sortKey": key.sortKey,
      "watchState": key.watchState, "searchTerm": key.searchTerm,
      "startIndex": key.startIndex, "limit": key.limit,
    ]
  }

  func key(_ key: PageQuery) -> [String: Any] {
    [
      "parentID": key.parentID, "kinds": key.kinds, "sortKey": key.sortKey,
      "watchState": key.watchState, "searchTerm": key.searchTerm,
    ]
  }

  func saveItems(
    _ items: [MediaItem], rail: String?, tenant: TenantID, now: Date,
    progressFresh: Bool, requestStartedAt: Date
  ) throws -> [MediaItem] {
    var a = args(tenant, now: now)
    a["items"] = try object(items)
    a["rail"] = rail
    a["progressFresh"] = progressFresh
    a["requestStartedAt"] = requestStartedAt.timeIntervalSince1970
    return try call("saveItems", a).decode([MediaItem].self)
  }

  func item(_ id: String, tenant: TenantID) throws -> CachedItem? {
    try call("item", ["tenantId": tenant.rawValue, "itemId": id]).decode(
      RustCacheRow<MediaItem>?.self)?.item()
  }

  func items(_ ids: [String], tenant: TenantID) throws -> [CachedItem] {
    try call("items", ["tenantId": tenant.rawValue, "ids": ids])
      .decode([RustCacheRow<MediaItem>].self).compactMap { $0.item() }
  }

  func posterCandidates(tenant: TenantID, limit: Int) throws -> [CachedItem] {
    try call("posterCandidates", ["tenantId": tenant.rawValue, "limit": limit])
      .decode([RustCacheRow<MediaItem>].self).compactMap { $0.item() }
  }

  func itemList(_ method: String, _ args: [String: Any]) throws -> [MediaItem] {
    try call(method, args).decode([RustCacheValue<MediaItem>].self).compactMap(\.value)
  }

  func recordProgress(
    item: MediaItem, position: Double, duration: Double?, tenant: TenantID,
    now: Date
  ) throws -> (state: MediaItem.PlayState, newerRecord: LocalPlaybackProgress?) {
    var a = args(tenant, now: now)
    a["item"] = try object(item)
    a["positionSeconds"] = position
    a["durationSeconds"] = duration
    let result = try call("recordPlaybackProgress", a).decode(RustProgressResult.self)
    return (
      result.state,
      result.newerRecord.map {
        LocalPlaybackProgress(
          item: $0.item, recordedAt: Date(timeIntervalSince1970: $0.recordedAt),
          confirmedAt: $0.confirmedAt.map { Date(timeIntervalSince1970: $0) },
          completed: $0.completed)
      }
    )
  }

  func libraries(tenant: TenantID) throws -> [CachedLibrary] {
    try call("libraries", args(tenant)).decode([RustCacheRow<MediaLibrary>].self).compactMap {
      $0.library()
    }
  }

  func rail(_ rail: String, tenant: TenantID) throws -> CachedRail? {
    try call("rail", ["tenantId": tenant.rawValue, "rail": rail]).decode(
      RustCacheRow<RailSnapshot>?.self)?.rail()
  }

  func home(tenant: TenantID) throws -> (libraries: [CachedLibrary], rails: [String: CachedRail]) {
    let parts = try call("home", args(tenant)).decode(RustHomeParts.self)
    return (parts.libraries.compactMap { $0.library() }, parts.rails.compactMapValues { $0.rail() })
  }

  func page(_ key: PageKey, tenant: TenantID) throws -> CachedPage? {
    try call("page", ["tenantId": tenant.rawValue, "key": self.key(key)])
      .decode(RustCacheRow<PageSnapshot>?.self)?.page()
  }

  func pages(_ query: PageQuery, tenant: TenantID) throws -> [CachedPage] {
    try call("pages", ["tenantId": tenant.rawValue, "key": self.key(query)])
      .decode([RustCacheRow<PageSnapshot>].self).compactMap { $0.page() }
  }

  func fileInfo(itemID: String, tenant: TenantID) throws -> CachedMediaFileInfo? {
    guard
      let row = try call("mediaFileInfo", ["tenantId": tenant.rawValue, "itemId": itemID])
        .decode(RustCacheRow<MediaFileInfo>?.self), let info = row.payload
    else { return nil }
    return CachedMediaFileInfo(info: info, fetchedAt: row.date)
  }

  func tmdbPayload(key: TMDbEntityKey, language: String) throws -> CachedTMDbPayload? {
    guard
      let row = try call("tmdbPayload", ["entityKey": key.storageKey, "language": language])
        .decode(RustCacheRow<TMDbEntityPayload>?.self), let payload = row.payload,
      payload.matches(key), let expires = row.expiresAt
    else { return nil }
    return CachedTMDbPayload(
      payload: payload, fetchedAt: row.date,
      expiresAt: Date(timeIntervalSince1970: expires))
  }

  func tmdbLink(itemID: String, tenant: TenantID) throws -> TMDbLink? {
    guard
      let row = try call("tmdbLink", ["tenantId": tenant.rawValue, "itemId": itemID])
        .decode(RustTMDbLink?.self), let key = TMDbEntityKey(storageKey: row.entityKey),
      let source = TMDbLinkSource(rawValue: row.source)
    else { return nil }
    return TMDbLink(
      itemID: itemID, entityKey: key, source: source, confidence: row.confidence,
      linkedAt: Date(timeIntervalSince1970: row.linkedAt))
  }
}

struct RustCacheResponse {
  let response: OcpResponse
  func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T { try response.decodeData(type) }
}
private struct RustCacheValue<Value: Decodable>: Decodable {
  let value: Value?
  init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
/// Decode each payload from the original typed container. Invalid payloads stay
/// cache misses without passing valid integer fields through JSONValue/Double.
private struct RustCacheRow<Payload: Decodable>: Decodable {
  var payload: Payload?
  var fetchedAt: Double
  var progressFetchedAt: Double?
  var startIndex: Int?
  var limit: Int?
  var expiresAt: Double?
  var date: Date { Date(timeIntervalSince1970: fetchedAt) }
  enum CodingKeys: String, CodingKey {
    case payload, fetchedAt, progressFetchedAt, startIndex, limit, expiresAt
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    payload = try? c.decode(Payload.self, forKey: .payload)
    fetchedAt = try c.decode(Double.self, forKey: .fetchedAt)
    progressFetchedAt = try c.decodeIfPresent(Double.self, forKey: .progressFetchedAt)
    startIndex = try c.decodeIfPresent(Int.self, forKey: .startIndex)
    limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
  }
}
extension RustCacheRow where Payload == MediaItem {
  fileprivate func item() -> CachedItem? {
    guard let payload else { return nil }
    return CachedItem(
      item: payload, fetchedAt: date,
      progressFetchedAt: progressFetchedAt.map { Date(timeIntervalSince1970: $0) })
  }
}
extension RustCacheRow where Payload == MediaLibrary {
  fileprivate func library() -> CachedLibrary? {
    guard let payload else { return nil }
    return CachedLibrary(library: payload, fetchedAt: date)
  }
}
extension RustCacheRow where Payload == RailSnapshot {
  fileprivate func rail() -> CachedRail? {
    guard let payload else { return nil }
    return CachedRail(items: payload.items, fetchedAt: date)
  }
}
extension RustCacheRow where Payload == PageSnapshot {
  fileprivate func page() -> CachedPage? {
    guard let payload else { return nil }
    return CachedPage(
      items: payload.items, totalRecordCount: payload.totalRecordCount, fetchedAt: date,
      startIndex: startIndex ?? 0, limit: limit ?? 0)
  }
}
private struct RustHomeParts: Decodable {
  var libraries: [RustCacheRow<MediaLibrary>]
  var rails: [String: RustCacheRow<RailSnapshot>]
}
private struct RustProgressResult: Decodable {
  var state: MediaItem.PlayState
  var newerRecord: RustLocalRecord?
}
private struct RustLocalRecord: Decodable {
  var item: MediaItem
  var recordedAt: Double
  var confirmedAt: Double?
  var completed: Bool
}
private struct RustTMDbLink: Decodable {
  var entityKey: String
  var source: String
  var confidence: Double
  var linkedAt: Double
}
