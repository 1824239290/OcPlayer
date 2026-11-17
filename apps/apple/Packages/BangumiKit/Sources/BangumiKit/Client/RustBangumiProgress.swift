import Foundation
import OcPlayerCore

/// Subject/progress effects; SQL applies only inside the retained database Core.
final class RustBangumiProgress: Sendable {
    let core: OcpCoreClient
    init(_ core: OcpCoreClient) { self.core = core }
    struct Start: Encodable, Sendable {
        var operation: String
        var subjectId, episodeId, type, rate: Int?
        var refreshEpisodes = false
        var authoritativeCollection = false
        var batch = false
        var prepareWatching = false
    }
    struct Arguments: Decodable, Sendable {
        var subjectId, episodeId, type, rate, limit, offset: Int?
        var batch, membership: Bool?
        var kind, reason: String?
    }
    struct Step: Decodable, Sendable {
        var token, sequence: UInt64
        var done: Bool
        var success, result: Bool?
        var effect: String?
        var arguments: Arguments?
    }
    struct Lookup: Encodable, Sendable {
        var state: String
        var interest: BangumiSubjectInterest?
        var reason: String?
        init(_ value: BangumiCollectionLookup) {
            switch value {
            case .collected(let interest): state = "collected"; self.interest = interest
            case .notCollected: state = "notCollected"
            case .unknown(let reason): state = "unknown"; self.reason = reason
            }
        }
    }
    struct Dependencies: Sendable {
        var validate: @Sendable () async throws -> Void
        var subject: @Sendable (Int) async throws -> BangumiSubjectDTO
        var lookup: @Sendable (Int) async -> BangumiCollectionLookup
        var episodes: @Sendable (Int, Int, Int) async throws -> BangumiPagedDTO<BangumiEpisodeDTO>
        var subjectMutation: @Sendable (Int, Int?, Int?) async throws -> Void
        var episodeMutation: @Sendable (Int, Int, Bool) async throws -> Void
        var notify: @MainActor @Sendable (Int, Bool) throws -> Void
        var now: @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
    }
    private struct Resume<Response: Encodable>: Encodable { var token, sequence: UInt64; var response: Response }
    private struct Apply: Encodable { var token, sequence: UInt64; var now: Int }
    private struct Failure: Encodable { var token, sequence: UInt64; var reason: String }
    func call<Input: Encodable, Output: Decodable>(_ method: String, _ input: Input, as: Output.Type = Output.self) throws -> Output {
        let response = try core.call("bangumiProgress." + method, argumentsJSON: String(decoding: JSONEncoder().encode(input), as: UTF8.self))
        guard response.ok else {
            if response.code == 1002, response.message.contains("retired") { throw BangumiError(ignore: "Progress work was retired") }
            throw BangumiError.request(response.message)
        }
        return try response.decodeData(Output.self)
    }
    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw BangumiError.request("Missing Core progress effect argument") }
        return value
    }
    private func resume<Response: Encodable>(_ step: Step, _ value: Response) throws -> Step {
        try call("resume", Resume(token: step.token, sequence: step.sequence, response: value))
    }
    func run(_ start: Start, dependencies: Dependencies) async throws -> Bool {
        try Task.checkCancellation(); try await dependencies.validate()
        var step: Step = try call("start", start)
        let token = step.token
        defer {
            do { let _: Bool = try call("cancel", ["token": token]) }
            catch { preconditionFailure("Cannot retire Bangumi progress: \(error)") }
        }
        var failure: Error?
        while !step.done {
            try Task.checkCancellation(); try await dependencies.validate()
            let effect = try Self.required(step.effect)
            let args = try Self.required(step.arguments)
            do {
                switch effect {
                case "database":
                    step = try call("apply", Apply(token: step.token, sequence: step.sequence, now: dependencies.now()))
                case "subject":
                    let subject = try await dependencies.subject(Self.required(args.subjectId))
                    try Task.checkCancellation(); try await dependencies.validate()
                    step = try resume(step, subject)
                case "lookup":
                    let lookup = await dependencies.lookup(try Self.required(args.subjectId))
                    try Task.checkCancellation(); try await dependencies.validate()
                    step = try resume(step, Lookup(lookup))
                case "episodes":
                    let page = try await dependencies.episodes(Self.required(args.subjectId), Self.required(args.limit), Self.required(args.offset))
                    try Task.checkCancellation(); try await dependencies.validate()
                    step = try resume(step, page)
                case "subjectMutation":
                    try await dependencies.subjectMutation(Self.required(args.subjectId), args.type, args.rate)
                    try Task.checkCancellation(); try await dependencies.validate()
                    step = try resume(step, true)
                case "episodeMutation":
                    try await dependencies.episodeMutation(Self.required(args.episodeId), Self.required(args.type), args.batch ?? false)
                    try Task.checkCancellation(); try await dependencies.validate()
                    step = try resume(step, true)
                case "notify":
                    try await dependencies.notify(Self.required(args.subjectId), args.membership ?? false)
                    try Task.checkCancellation(); try await dependencies.validate()
                    step = try resume(step, true)
                case "log":
                    if args.kind == "seasonCompleted" {
                        BangumiNetworkLog.logger.info("全部本篇已看，条目在看 → 看过 subject=\(args.subjectId ?? 0)")
                    } else if args.kind == "watchingAdvanced" {
                        BangumiNetworkLog.logger.info("自动推进条目为在看 subject=\(args.subjectId ?? 0)")
                    } else {
                        BangumiNetworkLog.logger.warning("进度操作 \(args.kind ?? "") subject=\(args.subjectId ?? 0) reason=\(args.reason ?? "")")
                    }
                    step = try resume(step, true)
                default: throw BangumiError.request("Unknown Core progress effect")
                }
            } catch {
                try Task.checkCancellation(); try await dependencies.validate()
                if error is CancellationError { throw error }
                if let error = error as? BangumiError, case .ignore = error { throw error }
                failure = error
                step = try call("fail", Failure(token: step.token, sequence: step.sequence, reason: String(describing: error)))
            }
        }
        try Task.checkCancellation(); try await dependencies.validate()
        guard step.success == true else { throw failure ?? BangumiError.request("Core progress operation failed") }
        return try Self.required(step.result)
    }
    func dependencies(db: BangumiDatabaseOperator, revision: UInt64) async -> Dependencies {
        let workRevision = await db.captureSyncRevision()
        let identity = await BangumiAPIClient.shared.syncIdentityGeneration()
        return Dependencies(
            validate: {
                guard db.isCurrentWorkRevision(workRevision), await MainActor.run(body: { revision == BangumiAuthService.syncOperationRevision }),
                      await BangumiAPIClient.shared.isCurrentSyncIdentity(identity) else { throw BangumiError(ignore: "Retired progress operation") }
            },
            subject: { try await BangumiSubjectService.getSubject($0) },
            lookup: { await BangumiContext.shared.lookupSubjectCollection($0) },
            episodes: { try await BangumiEpisodeService.getSubjectEpisodes($0, limit: $1, offset: $2) },
            subjectMutation: { subject, type, rate in
                try await BangumiCollectionService.updateSubjectCollection(subjectId: subject,
                    type: type.flatMap(BangumiCollectionType.init(rawValue:)), rate: rate)
            },
            episodeMutation: { episode, type, batch in
                guard let type = BangumiEpisodeCollectionType(rawValue: type) else { throw BangumiError.request("Invalid Core episode type") }
                try await BangumiEpisodeService.updateEpisodeCollection(episodeId: episode, type: type, batch: batch)
            },
            notify: { subject, membership in
                guard db.isCurrentWorkRevision(workRevision), revision == BangumiAuthService.syncOperationRevision else { throw BangumiError(ignore: "Retired progress notification") }
                BangumiProgressInvalidation.post(subjectId: subject, mayChangeProgressMembership: membership)
            })
    }
}
