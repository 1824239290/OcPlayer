import CoreModel
import Foundation
import OcPlayerCore

/// Typed continuations for enrichment. Core owns decisions and ordering; the
/// actor executes database, injected network and Swift task effects.
struct RustTMDbEnricher: Sendable {
  let core: OcpCoreClient
  static func make(libraryPath: String? = nil) -> Self? {
    guard libraryPath != nil || OcpCoreFeature.isEnabled,
      let core = try? OcpCoreClient(libraryPath: libraryPath)
    else { return nil }
    return Self(core: core)
  }
  func call<T: Decodable>(_ method: String, _ args: [String: Any], as: T.Type = T.self) throws -> T
  {
    let response = try core.call("tmdbEnrichment." + method, arguments: args)
    guard response.ok else { throw OcpCoreError(message: response.message) }
    return try response.decodeData(T.self)
  }
  func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }
  struct Cache: Encodable {
    var present = false
    var fetchedAt: Double = 0
    var expiresAt: Double = 0
    var airDates: [Double?]?
    var now: Double
    var startOfToday: Double
    init(_ cached: CachedTMDbPayload? = nil, season: TMDbSeason? = nil, now: Date = Date()) {
      self.now = now.timeIntervalSince1970
      startOfToday = Calendar.current.startOfDay(for: now).timeIntervalSince1970
      if let cached {
        present = true
        fetchedAt = cached.fetchedAt.timeIntervalSince1970
        expiresAt = cached.expiresAt.timeIntervalSince1970
        if case .season(let season) = cached.payload {
          airDates = season.episodes.map { TMDbAirDate.parse($0.airDate)?.timeIntervalSince1970 }
        }
      }
      if let season {
        airDates = season.episodes.map { TMDbAirDate.parse($0.airDate)?.timeIntervalSince1970 }
      }
    }
  }
  struct Failure: Codable, Sendable {
    let kind: String
    var message: String?
    var status: Int?
    var retryAfter: Double?
    init(_ error: TMDbError) {
      switch error {
      case .notConfigured: kind = "notConfigured"
      case .unauthorized: kind = "unauthorized"
      case .notFound: kind = "notFound"
      case .rateLimited(let value):
        kind = "rateLimited"
        retryAfter = value
      case .http(let value):
        kind = "http"
        status = value
      case .transport(let value):
        kind = "transport"
        message = value
      case .decoding(let value):
        kind = "decoding"
        message = value
      }
    }
    var native: TMDbError {
      switch kind {
      case "notConfigured": .notConfigured
      case "unauthorized": .unauthorized
      case "notFound": .notFound
      case "rateLimited": .rateLimited(retryAfter: retryAfter)
      case "http": .http(status: status ?? 0)
      case "decoding": .decoding(message ?? "")
      default: .transport(message ?? "")
      }
    }
  }
  struct Claim: Decodable {
    let owner: Bool
    let ticket: UInt64
  }
  struct Accepted: Decodable { let accepted: Bool }
  struct FailureResponse: Decodable { let failure: Failure? }
  struct Policy: Decodable {
    var value: Bool?
    var id: Int?
    var query: String?
  }
  func policy(_ operation: String, cache: Cache) throws -> Bool {
    let result: Policy = try call("policy", ["operation": operation, "cache": object(cache)])
    return result.value ?? false
  }
  struct Effect: Decodable {
    struct Arguments: Decodable {
      var entityKey: String?
      var source: String?
      var confidence: Double?
      var id: Int?
    }
    let kind: String
    let arguments: Arguments
  }
  struct Outcome: Decodable, Sendable {
    let kind: String
    let didFetch: Bool
    let seasons: Int
    var refresh: TMDbEnricher.RefreshOutcome {
      switch kind {
      case "skipped": .skipped
      case "fetched": .fetched
      case "noMatch": .noMatch
      default: .failed
      }
    }
  }
  struct State: Decodable {
    let step: UInt64
    let effect: Effect?
    let outcome: Outcome?
  }
  struct BatchProgress: Decodable {
    let completed, total, skipped, enriched, unmatched, failed, seasons: Int
    let currentTitle: String?
    var native: TMDbBatchProgress {
      .init(
        completed: completed, total: total, skipped: skipped, enriched: enriched,
        unmatched: unmatched,
        failed: failed, seasons: seasons, currentTitle: currentTitle)
    }
  }
  struct BatchState: Decodable {
    let dispatch: [Int]
    let active: Int
    let progress: BatchProgress
    let wasCancelled, finished, started: Bool
    var result: TMDbBatchResult {
      .init(
        processed: progress.completed, total: progress.total, skipped: progress.skipped,
        enriched: progress.enriched, unmatched: progress.unmatched, failed: progress.failed,
        seasons: progress.seasons, wasCancelled: wasCancelled)
    }
  }
}

extension TMDbEnricher {
  func sharedFlow(
    _ mode: String, item: MediaItem? = nil, itemID: String? = nil,
    tenant: TenantID? = nil, seriesLink: TMDbLink? = nil,
    entityKey: TMDbEntityKey? = nil, seasonNumber: Int? = nil,
    members: [MediaItem] = [], language: String? = nil
  ) async -> RustTMDbEnricher.Outcome? {
    guard let rust else { return nil }
    let language = language ?? preferences.language
    let id = UUID().uuidString
    defer { _ = try? rust.core.call("tmdbEnrichment.close", arguments: ["flowID": id]) }
    do {
      var config: [String: Any] = [
        "mode": mode, "configured": await client.isConfigured,
        "members": try rust.object(members.map(RustTMDbMatcher.Item.init)),
        "cancelled": Task.isCancelled,
      ]
      if let item { config["item"] = try rust.object(RustTMDbMatcher.Item(item)) }
      if let seriesLink { config["seriesLink"] = try rust.object(RustTMDbMatcher.Link(seriesLink)) }
      if let entityKey { config["entityKey"] = entityKey.storageKey }
      if let seasonNumber { config["seasonNumber"] = seasonNumber }
      let payload = String(
        decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
      var state: RustTMDbEnricher.State = try rust.call(
        "begin", ["flowID": id, "payloadJSON": payload])
      while state.outcome == nil {
        guard let effect = state.effect else {
          throw OcpCoreError(message: "Missing enrichment effect")
        }
        let value: Any
        switch effect.kind {
        case "link":
          guard let item, let tenant else { throw OcpCoreError(message: "Missing link context") }
          if let link = try? await store.tmdbLink(itemID: item.id, tenant: tenant) {
            value = try rust.object(RustTMDbMatcher.Link(link))
          } else {
            value = NSNull()
          }
        case "cache", "hasPayload", "seriesPayload":
          guard let raw = effect.arguments.entityKey, let key = TMDbEntityKey(storageKey: raw)
          else { throw OcpCoreError(message: "Missing cache key") }
          let cached = try? await store.tmdbPayload(key: key, language: language)
          if effect.kind == "hasPayload" {
            value = cached != nil
          } else if effect.kind == "seriesPayload" {
            if let cached, case .entity(let entity) = cached.payload {
              value = entity.seasons.map(\.seasonNumber)
            } else {
              value = NSNull()
            }
          } else {
            value = try rust.object(RustTMDbEnricher.Cache(cached))
          }
        case "match":
          guard let item else { throw OcpCoreError(message: "Missing match item") }
          let matcher = RustTMDbMatcher(core: rust.core)
          let match = try await matcher.match(
            item: item, seriesLink: seriesLink, allowSearch: true, language: language
          ) { [client] query, type, year, language in
            try await client.search(query: query, mediaType: type, year: year, language: language)
          }
          if let match {
            let link = TMDbLink(
              itemID: item.id, entityKey: match.entityKey, source: match.source,
              confidence: match.confidence, linkedAt: Date())
            value = try rust.object(RustTMDbMatcher.Link(link))
          } else {
            value = NSNull()
          }
        case "saveLink":
          guard let itemID = itemID ?? item?.id, let tenant,
            let raw = effect.arguments.entityKey, let key = TMDbEntityKey(storageKey: raw),
            let source = effect.arguments.source.flatMap(TMDbLinkSource.init(rawValue:)),
            let confidence = effect.arguments.confidence
          else { throw OcpCoreError(message: "Missing link effect") }
          try? await store.saveTMDbLink(
            itemID: itemID, entityKey: key, source: source, confidence: confidence, tenant: tenant)
          value = NSNull()
        case "fetch":
          guard let raw = effect.arguments.entityKey, let key = TMDbEntityKey(storageKey: raw)
          else { throw OcpCoreError(message: "Missing fetch key") }
          value = await fetchAndStore(
            key: key, language: ["bind", "season"].contains(mode) ? nil : language)
        case "member":
          guard let id = effect.arguments.id else {
            throw OcpCoreError(message: "Missing member ID")
          }
          do {
            let entity = try await client.movie(id: id, language: language)
            var result: [String: Any] = ["success": true]
            result["collectionID"] = entity.collectionID
            value = result
          } catch { value = ["success": false] }
        case "refresh":
          guard let item, let tenant else { throw OcpCoreError(message: "Missing refresh context") }
          switch await performRefresh(item: item, tenant: tenant) {
          case .skipped: value = "skipped"
          case .fetched: value = "fetched"
          case .noMatch: value = "noMatch"
          case .failed: value = "failed"
          }
        case "seasons":
          guard let item, let tenant else { throw OcpCoreError(message: "Missing season context") }
          value = await enrichSeasons(ofSeries: item, tenant: tenant)
        default: throw OcpCoreError(message: "Unknown enrichment effect")
        }
        let reply: [String: Any] = ["value": value, "cancelled": Task.isCancelled]
        let payload = String(
          decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
        state = try rust.call(
          "advance", ["flowID": id, "step": state.step, "payloadJSON": payload])
      }
      return state.outcome
    } catch {
      // A dispatched shared flow must not replay its writes in the native path.
      return nil
    }
  }

  func sharedBatch(
    items: [MediaItem], tenant: TenantID,
    onProgress: @Sendable (TMDbBatchProgress) async -> Void
  ) async -> TMDbBatchResult {
    let empty = TMDbBatchResult(
      processed: 0, total: items.count, skipped: 0, enriched: 0, unmatched: 0, failed: 0,
      seasons: 0, wasCancelled: false)
    guard let rust else { return empty }
    let id = UUID().uuidString
    defer { _ = try? rust.core.call("tmdbEnrichment.batch.close", arguments: ["batchID": id]) }
    do {
      var state: RustTMDbEnricher.BatchState = try rust.call(
        "batch.begin",
        [
          "batchID": id, "configured": await client.isConfigured,
          "items": rust.object(items.map(RustTMDbMatcher.Item.init)),
        ])
      guard state.started else { return state.result }
      await onProgress(state.progress.native)
      struct Completion: Sendable {
        let index: Int
        let outcome: String
        let seasons: Int
      }
      await withTaskGroup(of: Completion.self) { group in
        let observer = Self.workerObserver
        func dispatch(_ indices: [Int], after active: Int) {
          var count = active - indices.count
          for index in indices {
            count += 1
            observer?(count)
            let item = items[index]
            group.addTask {
              let outcome = await self.sharedFlow("contribution", item: item, tenant: tenant)
              return Completion(
                index: index, outcome: outcome?.kind ?? "failed", seasons: outcome?.seasons ?? 0)
            }
          }
        }
        dispatch(state.dispatch, after: state.active)
        for await completion in group {
          do {
            state = try rust.call(
              "batch.complete",
              [
                "batchID": id, "index": completion.index, "outcome": completion.outcome,
                "seasons": completion.seasons,
              ])
            observer?(state.active)
            await onProgress(state.progress.native)
            state = try rust.call("batch.refill", ["batchID": id, "cancelled": Task.isCancelled])
            dispatch(state.dispatch, after: state.active)
          } catch { /* Drain already-dispatched workers; never replay a batch. */  }
        }
      }
      var final = state.progress.native
      final.currentTitle = nil
      await onProgress(final)
      return state.result
    } catch { return empty }
  }
}
