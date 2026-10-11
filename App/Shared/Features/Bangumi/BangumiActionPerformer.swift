import BangumiKit
import Foundation

/// Bangumi 提交类操作（标集 / 改条目状态）的统一执行外壳：忙标志互斥、错误文案
/// （BangumiError → userMessage，其余 → 描述串）、诊断日志三件套只此一份。
/// 进度页、条目详情页、详情页章节区曾各抄一份，改一处忘两处。
@MainActor
enum BangumiActionPerformer {
    /// - Parameters:
    ///   - label: 诊断日志里的操作描述（含条目/集标识）。
    ///   - isBusy: 当前是否已有提交在途（在途直接丢弃新请求）。
    ///   - setBusy: 忙标志写口（true 进 / false 出，defer 保证复位）。
    ///   - operation: 真正的提交体（抛错即走 onError）。
    ///   - onSuccess: 提交成功后的重读/清错（章节区在这里比 loadGeneration）。
    ///   - onError: 错误文案落点。
    static func run(
        _ label: String,
        isBusy: Bool,
        setBusy: (Bool) -> Void,
        operation: () async throws -> Void,
        onSuccess: () async -> Void,
        onError: (String) -> Void
    ) async {
        guard !isBusy else { return }
        setBusy(true)
        defer { setBusy(false) }
        do {
            try await operation()
            await onSuccess()
        } catch let e as BangumiError {
            onError(e.userMessage)
            BangumiDiagnostics.log("\(label) error=\(e)", level: .warning)
        } catch {
            onError("\(error)")
            BangumiDiagnostics.log("\(label) error=\(error)", level: .warning)
        }
    }

    /// 加载类失败的统一收尾：返回给页面的错误文案（BangumiError → userMessage，
    /// 其余 → 描述串）+ 诊断日志。提交类操作走 `run`；各加载骨架的 catch 用这个，
    /// 不再每处写两个 catch 分支。
    static func loadFailureMessage(_ label: String, _ error: any Error) -> String {
        if let e = error as? BangumiError {
            BangumiDiagnostics.log("\(label) error=\(e)", level: .warning)
            return e.userMessage
        }
        BangumiDiagnostics.log("\(label) error=\(error)", level: .warning)
        return "\(error)"
    }

    /// 「标记单集 / 看到此集」特化：忙标志按集 id 记（格子各自转圈）。
    static func performEpisodeAction(
        _ action: BangumiEpisodeAction,
        on episode: BangumiEpisodeDTO,
        context: BangumiContext,
        isBusy: Bool,
        setBusy: (Int?) -> Void,
        onSuccess: () async -> Void,
        onError: (String) -> Void
    ) async {
        await run(
            "标记章节失败 episode=\(episode.id)",
            isBusy: isBusy,
            setBusy: { setBusy($0 ? episode.id : nil) },
            operation: {
                switch action {
                case .set(let type):
                    try await context.updateEpisodeCollection(
                        episodeId: episode.id, type: type)
                case .markUpTo:
                    try await context.updateEpisodeCollection(
                        episodeId: episode.id, type: .collect, batch: true)
                }
            },
            onSuccess: onSuccess,
            onError: onError
        )
    }
}
