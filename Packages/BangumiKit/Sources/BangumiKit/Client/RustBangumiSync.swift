import Foundation
import OcPlayerCore

/// Executes effects from retained Core flows. SQL effects never return to Swift:
/// Core validates and applies their receipt under its database-state lock.
final class RustBangumiSync: Sendable {
    let core: OcpCoreClient
    init(core: OcpCoreClient) { self.core = core }
    struct Start: Encodable, Sendable {
        var operation: String
        var since: Int = 0
        var startedAt: Int = 0
        var force: Bool = false
        var maxConcurrent: Int = 4
        var authoritativeCollection: Bool = false
        var subjectId: Int? = nil
        var parentToken: UInt64? = nil
        var parentJob: UInt64? = nil
    }
    struct Job: Decodable, Sendable { var id: UInt64; var subjectId: Int }
    struct Arguments: Decodable, Sendable {
        var since, limit, offset, value, subjectId: Int?
        var jobs: [Job]?
        var authoritativeCollection: Bool?
    }
    struct Step<Output: Decodable & Sendable>: Decodable, Sendable {
        var token, sequence: UInt64
        var done: Bool
        var effect: String?
        var arguments: Arguments?
        var result: Output?
    }
    struct Resume<Response: Encodable>: Encodable {
        var token, sequence: UInt64
        var response: Response
    }
    struct Dependencies: Sendable {
        var collections: @Sendable (Int, Int, Int) async throws -> BangumiPagedDTO<BangumiSubjectDTO>
        var episodes: @Sendable (Int, Int, Int) async throws -> BangumiPagedDTO<BangumiEpisodeDTO>
        var targets: @Sendable () async throws -> [Int]
        var timestamp: @MainActor @Sendable (Int) throws -> Void
        var validate: @Sendable () async throws -> Void
        var now: @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
    }
    func call<Input: Encodable, Output: Decodable>(_ method: String, _ input: Input, as: Output.Type = Output.self) throws -> Output {
        let response = try core.call("bangumiSync." + method, argumentsJSON: String(decoding: JSONEncoder().encode(input), as: UTF8.self))
        guard response.ok else {
            if response.code == 1002, response.message.contains("retired") { throw BangumiError(ignore: "Synchronization was retired") }
            throw BangumiError.request(response.message)
        }
        return try response.decodeData(Output.self)
    }
    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw BangumiError.request("Missing Core sync effect argument") }
        return value
    }
    struct Stats: Decodable { var active: Int; var epoch: UInt64 }
    func invalidate() {
        let _: Stats? = try? call("invalidate", [String: String]())
    }
    private func cancel(_ token: UInt64) {
        let _: Bool? = try? call("cancel", ["token": token])
    }
    private func resume<Response: Encodable, Output: Decodable & Sendable>(_ step: Step<Output>, _ response: Response) throws -> Step<Output> {
        try call("resume", Resume(token: step.token, sequence: step.sequence, response: response))
    }
    func run<Output: Decodable & Sendable>(_ start: Start, dependencies: Dependencies, as: Output.Type = Output.self) async throws -> Output {
        try Task.checkCancellation()
        try await dependencies.validate()
        var step: Step<Output> = try call("start", start)
        defer { cancel(step.token) }
        while !step.done {
            try Task.checkCancellation()
            try await dependencies.validate()
            let effect = try Self.required(step.effect)
            let args = try Self.required(step.arguments)
            switch effect {
            case "collections":
                let page = try await dependencies.collections(Self.required(args.since), Self.required(args.limit), Self.required(args.offset))
                try Task.checkCancellation(); try await dependencies.validate()
                step = try resume(step, page)
            case "episodes":
                let page = try await dependencies.episodes(Self.required(args.subjectId), Self.required(args.limit), Self.required(args.offset))
                try Task.checkCancellation(); try await dependencies.validate()
                step = try resume(step, page)
            case "saveSubjects", "replaceEpisodes":
                step = try call("apply", Apply(token: step.token, sequence: step.sequence, now: dependencies.now()))
            case "timestamp":
                try await dependencies.timestamp(Self.required(args.value))
                step = try resume(step, true)
            case "targets":
                let targets = (try? await dependencies.targets()) ?? []
                try Task.checkCancellation(); try await dependencies.validate()
                step = try resume(step, targets)
            case "episodeBatch": step = try await batch(step, dependencies: dependencies)
            default: throw BangumiError.request("Unknown Core sync effect: \(effect)")
            }
        }
        return try Self.required(step.result)
    }
    private struct Apply: Encodable { var token, sequence: UInt64; var now: Int }
    private struct Completion: Encodable { var token, jobId: UInt64; var succeeded: Bool }
    private func batch<Output: Decodable & Sendable>(_ initial: Step<Output>, dependencies: Dependencies) async throws -> Step<Output> {
        let parent = initial.token
        let authoritative = initial.arguments?.authoritativeCollection ?? false
        let work: @Sendable (Job) async -> (UInt64, Bool) = { job in
            do {
                let completed: Bool = try await self.run(Start(operation: "episodes", authoritativeCollection: authoritative,
                    subjectId: job.subjectId, parentToken: parent, parentJob: job.id), dependencies: dependencies)
                return (job.id, completed)
            } catch {
                BangumiNetworkLog.logger.warning("章节补齐失败 subject=\(job.subjectId) error=\(error)")
                return (job.id, false)
            }
        }
        return try await withThrowingTaskGroup(of: (UInt64, Bool).self) { group in
            var step = initial
            for job in initial.arguments?.jobs ?? [] { group.addTask { await work(job) } }
            while let (job, succeeded) = try await group.next() {
                try Task.checkCancellation(); try await dependencies.validate()
                step = try call("batchComplete", Completion(token: parent, jobId: job, succeeded: succeeded))
                if step.done { return step }
                for job in step.arguments?.jobs ?? [] { group.addTask { await work(job) } }
            }
            throw BangumiError.request("Core sync batch ended without a result")
        }
    }
    func dependencies(db: BangumiDatabaseOperator, store: BangumiStore? = nil, revision expectedRevision: UInt64? = nil) async -> Dependencies {
        let revision: UInt64
        if let expectedRevision { revision = expectedRevision }
        else { revision = await MainActor.run { BangumiAuthService.syncOperationRevision } }
        let identity = await BangumiAPIClient.shared.syncIdentityGeneration()
        return Dependencies(
            collections: { try await BangumiCollectionService.getSubjectCollections(since: $0, limit: $1, offset: $2) },
            episodes: { try await BangumiEpisodeService.getSubjectEpisodes($0, limit: $1, offset: $2) },
            targets: { try await db.fetchEpisodeSyncTargets() },
            timestamp: { value in
                guard revision == BangumiAuthService.syncOperationRevision else { throw BangumiError(ignore: "Discarded stale synchronization timestamp") }
                store?.setCollectionsUpdatedAt(value)
            },
            validate: {
                let current = await MainActor.run { revision == BangumiAuthService.syncOperationRevision }
                guard current else { throw BangumiError(ignore: "Discarded stale synchronization operation") }
                guard await BangumiAPIClient.shared.isCurrentSyncIdentity(identity) else { throw BangumiError(ignore: "Discarded stale account synchronization") }
            })
    }
}
