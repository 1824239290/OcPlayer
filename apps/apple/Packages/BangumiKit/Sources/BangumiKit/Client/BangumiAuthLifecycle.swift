import Foundation

/// Fallback operation retirement and credential clearing share this lock.
final class BangumiAuthOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    var current: UInt64 { lock.withLock { revision } }
    func begin() -> UInt64 { lock.withLock { revision &+= 1; return revision } }
    func withCurrent<T>(_ expected: UInt64, _ work: () -> T) -> T? {
        lock.withLock { guard revision == expected else { return nil }; return work() }
    }
}

@MainActor
final class BangumiAuthLifecycle {
    struct Effects: Sendable {
        var retireWork: @MainActor @Sendable () -> Void
        var fetchProfile: @Sendable () async throws -> BangumiProfile
        var commitProfile: @MainActor @Sendable (BangumiProfile) async throws -> Void
        var clearProfile: @MainActor @Sendable () -> Void
        var clearDatabase: @MainActor @Sendable (UInt64) async throws -> Void
        var authenticated: @MainActor @Sendable () -> Bool
    }
    let client: BangumiAPIClient
    let flow: RustBangumiAuthFlow?
    let nativeOperations = BangumiAuthOperations()
    let effects: Effects
    init(client: BangumiAPIClient, effects: Effects) {
        self.client = client; self.effects = effects
        flow = client.account.map { RustBangumiAuthFlow($0.core) }
    }
    var operationRevision: UInt64 { client.account?.snapshot.operationRevision ?? nativeOperations.current }
    private func begin() -> UInt64 {
        let revision = nativeOperations.begin()
        effects.retireWork()
        return revision
    }
    private func ensureCurrent(_ revision: UInt64) throws {
        guard operationRevision == revision else { throw BangumiError(ignore: "Retired authentication operation") }
    }
    private func validate(_ revision: UInt64, identity: UInt64) async throws {
        try ensureCurrent(revision)
        guard await client.isCurrentSyncIdentity(identity) else { throw BangumiError(ignore: "Retired authentication identity") }
        try ensureCurrent(revision)
    }
    func exchange(code: String, state: String) async throws {
        try Task.checkCancellation()
        if flow != nil { _ = try await run(.init(operation: "exchange"), code: code, state: state); return }
        let revision = begin()
        let receipt = try await client.exchangeForAuthLifecycle(code: code, state: state)
        try await validate(revision, identity: receipt.identity)
        do {
            _ = try await refresh(revision: revision, identity: receipt.identity)
        } catch {
            _ = await client.clearCredentials(forOperation: revision, ifCurrent: receipt.generation, nativeOperations: nativeOperations)
            throw error
        }
    }
    func refreshProfile() async throws -> BangumiProfile {
        try Task.checkCancellation()
        if flow != nil {
            guard let profile = try await run(.init(operation: "refreshProfile")) else { throw BangumiError.request("Missing profile effect result") }
            return profile
        }
        let revision = begin(), identity = await client.syncIdentityGeneration()
        try await validate(revision, identity: identity)
        return try await refresh(revision: revision, identity: identity)
    }
    private func refresh(revision: UInt64, identity: UInt64) async throws -> BangumiProfile {
        try Task.checkCancellation()
        let profile = try await effects.fetchProfile()
        try Task.checkCancellation(); try await validate(revision, identity: identity)
        try await effects.commitProfile(profile)
        try Task.checkCancellation(); try await validate(revision, identity: identity)
        return profile
    }
    func logout() async {
        if flow != nil {
            do { _ = try await run(.init(operation: "logout")) }
            catch { if case .ignore = error as? BangumiError { return }; preconditionFailure("Bangumi logout contract failed: \(error)") }
            return
        }
        let revision = begin(); effects.clearProfile()
        guard await client.clearCredentials(forOperation: revision, nativeOperations: nativeOperations) != nil else { return }
        guard operationRevision == revision else { return }
        try? await effects.clearDatabase(revision)
    }
    func invalidateSession(expectedGeneration: UInt64) async {
        if flow != nil {
            do { _ = try await run(.init(operation: "invalidateSession", authenticated: effects.authenticated(), expectedGeneration: expectedGeneration)) }
            catch { if case .ignore = error as? BangumiError { return }; preconditionFailure("Bangumi invalidation contract failed: \(error)") }
            return
        }
        guard effects.authenticated() else { return }
        let observed = operationRevision
        guard let cleared = await client.clearCredentials(forOperation: observed, ifCurrent: expectedGeneration, nativeOperations: nativeOperations) else { return }
        guard operationRevision == observed, await client.isCurrentCredentialGeneration(cleared), operationRevision == observed else { return }
        _ = begin(); effects.clearProfile()
    }
    private func run(_ initial: RustBangumiAuthFlow.Start, code: String = "", state: String = "") async throws -> BangumiProfile? {
        guard let flow else { throw BangumiError.request("Missing selected authentication Core") }
        var step: RustBangumiAuthFlow.Step = try flow.call("start", initial)
        let token = step.token; defer { flow.cancel(token) }
        let cancellable = initial.operation == "exchange" || initial.operation == "refreshProfile"
        var profile: BangumiProfile?, failure: Error?
        while !step.done {
            do {
                try flow.validate(step)
                if cancellable && step.cleanup != true && step.effect != "retireWork" { try Task.checkCancellation() }
                switch step.effect {
                case "retireWork": effects.retireWork(); step = try flow.resume(step, true)
                case "exchange":
                    let receipt = try await client.exchangeForAuthLifecycle(code: code, state: state)
                    step = try flow.resume(step, receipt)
                case "fetchProfile":
                    let fetched = try await effects.fetchProfile()
                    try Task.checkCancellation()
                    profile = fetched; step = try flow.resume(step, true)
                case "commitProfile":
                    guard let profile else { throw BangumiError.request("Missing fetched profile") }
                    try await effects.commitProfile(profile)
                    try Task.checkCancellation(); step = try flow.resume(step, true)
                case "clearProfile": effects.clearProfile(); step = try flow.resume(step, true)
                case "clearCredentials":
                    guard let args = step.arguments else { throw BangumiError.request("Missing clear-credential receipt") }
                    let generation = await client.clearCredentials(forOperation: args.operationRevision,
                        ifCurrent: args.expectedGeneration, nativeOperations: nativeOperations)
                    step = try flow.resume(step, RustBangumiAuthFlow.Cleared(generation: generation))
                case "clearDatabase":
                    try await effects.clearDatabase(step.operationRevision)
                    step = try flow.resume(step, true)
                default: throw BangumiError.request("Unknown authentication effect")
                }
            } catch {
                if case .ignore = error as? BangumiError { throw failure ?? error }
                failure = failure ?? error
                do { step = try flow.call("fail", RustBangumiAuthFlow.Receipt(token: step.token, sequence: step.sequence)) }
                catch { if case .ignore = error as? BangumiError { throw failure ?? error }; throw error }
            }
        }
        guard step.success == true else { throw failure ?? BangumiError.request("Authentication effect failed") }
        return profile
    }
}
