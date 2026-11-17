import CErika
import PlaybackKit
import Testing
@testable import ErikaKit

/// `ErikaOutputStatus` → `PlaybackOutputSnapshot` 的纯映射。
///
/// 这块的价值全在「**别丢字段、别猜**」：内核承诺回退原因码只追加不重编号 0…8，
/// 所以映射必须逐值对齐；超出范围（内核比 App 新）时回落 `.unknown` 而不是挑一个
/// 最像的——猜错会让排查 HDR 问题时走错方向，比「未知」更坏。
/// 纯函数、不实例化 presenter，所以无 GPU 的 CI 也能跑。
@Suite("Erika 输出状态映射")
struct ErikaOutputSnapshotTests {

    @Test("回退原因码 0…8 逐个对齐内核枚举")
    func mapsEveryFallbackReason() throws {
        let pairs: [(ErikaOutputFallbackReason, PlaybackOutputSnapshot.FallbackReason)] = [
            (ErikaOutputFallbackReason_None, .none),
            (ErikaOutputFallbackReason_DisplayHdrUnsupported, .displayHdrUnsupported),
            (ErikaOutputFallbackReason_HybridCompositionRequired, .hybridCompositionRequired),
            (ErikaOutputFallbackReason_WgpuBackendNotVulkan, .wgpuBackendNotVulkan),
            (ErikaOutputFallbackReason_Rgba16FloatSurfaceFormatUnavailable,
             .rgba16FloatSurfaceFormatUnavailable),
            (ErikaOutputFallbackReason_NativeWindowDataSpaceApiUnavailable,
             .nativeWindowDataSpaceApiUnavailable),
            (ErikaOutputFallbackReason_ScrgbDataSpaceVerificationFailed,
             .scrgbDataSpaceVerificationFailed),
            (ErikaOutputFallbackReason_SurfaceConfigureFailed, .surfaceConfigureFailed),
            (ErikaOutputFallbackReason_LegacyAppleEdrUnsupported, .legacyAppleEdrUnsupported),
        ]
        for (raw, expected) in pairs {
            #expect(
                PlaybackOutputSnapshot.FallbackReason(Int32(raw.rawValue)) == expected,
                "回退码 \(raw.rawValue) 映射错了——这是 ABI 承诺的稳定编号"
            )
        }
    }

    @Test("不认识的回退码回落 unknown，不挑一个最像的")
    func unknownFallbackReasonIsNotGuessed() {
        #expect(PlaybackOutputSnapshot.FallbackReason(9) == .unknown)
        #expect(PlaybackOutputSnapshot.FallbackReason(99) == .unknown)
        #expect(PlaybackOutputSnapshot.FallbackReason(-1) == .unknown)
    }

    @Test("面格式三档对齐，其余回落 unknown")
    func mapsSurfaceFormat() {
        #expect(PlaybackOutputSnapshot.SurfaceFormat(
            Int32(ErikaOutputSurfaceFormat_EightBitUnorm.rawValue)) == .eightBitUnorm)
        #expect(PlaybackOutputSnapshot.SurfaceFormat(
            Int32(ErikaOutputSurfaceFormat_TenBitUnorm.rawValue)) == .tenBitUnorm)
        #expect(PlaybackOutputSnapshot.SurfaceFormat(
            Int32(ErikaOutputSurfaceFormat_SixteenBitFloat.rawValue)) == .sixteenBitFloat)
        #expect(PlaybackOutputSnapshot.SurfaceFormat(7) == .unknown)
    }

    @Test("headroom 只在内核说 known 时才算数")
    func headroomRequiresKnownFlag() {
        var raw = ErikaOutputStatus()
        raw.active_headroom = 8.0
        raw.active_headroom_known = false
        // 内核在不知道显示器比例时也会填一个「有效内容回退值」；把它当权威读数
        // 会把 SDR 屏报成 HDR 就绪。
        #expect(PlaybackOutputSnapshot(raw).activeHeadroom == nil)
        #expect(PlaybackOutputSnapshot(raw).activeHeadroomKnown == false)

        raw.active_headroom_known = true
        #expect(PlaybackOutputSnapshot(raw).activeHeadroom == 8.0)
    }

    @Test("字段原样映射：面格式 / 回退 / 计数 / 扩展线性")
    func mapsRemainingFields() {
        var raw = ErikaOutputStatus()
        raw.surface_format = Int32(ErikaOutputSurfaceFormat_TenBitUnorm.rawValue)
        raw.fallback_reason = Int32(ErikaOutputFallbackReason_DisplayHdrUnsupported.rawValue)
        raw.fallback_count = 3
        raw.extended_linear_active = true

        let snapshot = PlaybackOutputSnapshot(raw)
        #expect(snapshot.surfaceFormat == .tenBitUnorm)
        #expect(snapshot.fallbackReason == .displayHdrUnsupported)
        #expect(snapshot.fallbackCount == 3)
        #expect(snapshot.extendedLinearActive)
    }

    @Test("中性默认值：全 0 的 C 结构不产生假回退")
    func defaultIsNeutral() {
        // 全零的 C 结构里 fallback_reason = 0 = None、surface_format = 0 = 8bit，
        // 都是「内核还没报」的合法取值，不应被解读成异常。
        let snapshot = PlaybackOutputSnapshot(ErikaOutputStatus())
        #expect(snapshot.fallbackReason == .none)
        #expect(snapshot.surfaceFormat == .eightBitUnorm)
        #expect(snapshot.activeHeadroom == nil)
        // 中性构造（非 Erika 内核 / 打开中）用 none 而不是 unknown：后者会让 UI
        // 对拿不到信息的内核显示「回退（原因未识别）」。
        #expect(PlaybackOutputSnapshot.unknown.fallbackReason == .none)
        #expect(PlaybackOutputSnapshot.unknown.surfaceFormat == .unknown)
    }

    @Test("日志字段用内核的稳定 rawValue，不是本地化文案")
    func logFieldsUseStableLabels() {
        var raw = ErikaOutputStatus()
        raw.surface_format = Int32(ErikaOutputSurfaceFormat_SixteenBitFloat.rawValue)
        raw.fallback_reason = Int32(ErikaOutputFallbackReason_LegacyAppleEdrUnsupported.rawValue)
        raw.fallback_count = 2

        let fields = PlaybackOutputSnapshot(raw).logFields
        #expect(fields["surface_format"] == .string("sixteenBitFloat"))
        // 与 erika.h 的表一致：日志里必须是 snake_case 的稳定标签，便于和内核 stderr 对照。
        #expect(fields["fallback_reason"] == .string("legacy_apple_edr_unsupported"))
        #expect(fields["fallback_count"] == .unsignedInteger(2))
        #expect(fields["headroom"] == .null)
    }

    // MARK: - 「变化才记」的判据（输出日志每 5s 一次的降噪基准）

    @Test("语义量没变就不记：累计计数不该把日志刷成逐次一条")
    func cumulativeCountersDoNotTriggerALog() {
        var baseline = ErikaOutputStatus()
        baseline.fallback_count = 1

        var later = baseline
        // 这两个是**累计计数**，每次采样都在涨。
        later.headroom_updates = 17
        later.data_space_failures = 3
        later.extended_linear_frames = 900
        #expect(
            !ErikaEngine.isMeaningfulOutputChange(from: baseline, to: later),
            "累计计数变化不是「输出变了」，否则 5s 一次会变成每次一条"
        )
    }

    @Test("每一次真正的语义变化都要能触发记录")
    func eachMeaningfulFieldTriggersALog() {
        let baseline = ErikaOutputStatus()

        var surfaceFormat = baseline
        surfaceFormat.surface_format = Int32(ErikaOutputSurfaceFormat_TenBitUnorm.rawValue)
        #expect(ErikaEngine.isMeaningfulOutputChange(from: baseline, to: surfaceFormat))

        var fallbackReason = baseline
        fallbackReason.fallback_reason = Int32(ErikaOutputFallbackReason_DisplayHdrUnsupported.rawValue)
        #expect(ErikaEngine.isMeaningfulOutputChange(from: baseline, to: fallbackReason))

        var fallbackCount = baseline
        fallbackCount.fallback_count = 1
        #expect(ErikaEngine.isMeaningfulOutputChange(from: baseline, to: fallbackCount))

        var headroom = baseline
        headroom.active_headroom = 8.0
        #expect(ErikaEngine.isMeaningfulOutputChange(from: baseline, to: headroom))

        var known = baseline
        known.active_headroom_known = true
        #expect(ErikaEngine.isMeaningfulOutputChange(from: baseline, to: known))

        var extendedLinear = baseline
        extendedLinear.extended_linear_active = true
        #expect(ErikaEngine.isMeaningfulOutputChange(from: baseline, to: extendedLinear))

        var encoding = baseline
        encoding.active_encoding = Int32(ErikaActiveOutputEncoding_AppleEdr.rawValue)
        #expect(ErikaEngine.isMeaningfulOutputChange(from: baseline, to: encoding))
    }

    @Test("完全相同的两份状态不重复记录")
    func identicalStatusIsNotReLogged() {
        var raw = ErikaOutputStatus()
        raw.surface_format = Int32(ErikaOutputSurfaceFormat_TenBitUnorm.rawValue)
        raw.fallback_count = 2
        #expect(!ErikaEngine.isMeaningfulOutputChange(from: raw, to: raw))
    }
}
