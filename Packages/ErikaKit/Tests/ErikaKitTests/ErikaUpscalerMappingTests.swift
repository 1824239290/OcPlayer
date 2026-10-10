import CErika
import PlaybackKit
import Testing
@testable import ErikaKit

/// 亮度上采样档位的映射与状态解读。
///
/// 这块最怕的是**档位错位**：用户选了「F16 去噪」而内核跑 F32，画面上看不出差别，
/// 只有显存占用和帧率会说话——所以四个档位逐个钉住，且**不靠 rawValue 互转**
/// （两份枚举是各自独立演进的，靠数值对齐等于把它们的顺序绑死）。
/// 纯映射、不实例化 presenter，无 GPU 也能跑。
@Suite("亮度上采样映射")
struct ErikaUpscalerMappingTests {

    @Test("四个档位逐个对齐内核枚举，且往返一致")
    func mapsEveryModeBothWays() {
        let pairs: [(PlaybackUpscalerMode, ErikaLumaUpscalerMode)] = [
            (.off, ErikaLumaUpscalerMode_Off),
            (.artCnnC4F16, ErikaLumaUpscalerMode_ArtCnnC4F16),
            (.artCnnC4F32, ErikaLumaUpscalerMode_ArtCnnC4F32),
            (.artCnnC4F16Ds, ErikaLumaUpscalerMode_ArtCnnC4F16Ds),
        ]
        for (neutral, kernel) in pairs {
            #expect(neutral.erikaValue == kernel, "\(neutral.rawValue) 映射到内核枚举错了")
            #expect(PlaybackUpscalerMode(Int32(kernel.rawValue)) == neutral, "反向映射错了")
        }
    }

    @Test("不认识的档位码回落 off（不会莫名打开一个用户没要的增强）")
    func unknownModeFallsBackToOff() {
        #expect(PlaybackUpscalerMode(99) == .off)
        #expect(PlaybackUpscalerMode(-1) == .off)
    }

    @Test("每档都有设置页可显示的名字")
    func everyModeHasADisplayName() {
        for mode in PlaybackUpscalerMode.allCases {
            #expect(!mode.displayName.isEmpty)
        }
        #expect(PlaybackUpscalerMode.allCases.count == 4, "档位数量变了要同步设置页文案")
    }

    @Test("后端状态 0…4 逐个对齐，未知值回落 unknown")
    func mapsBackendStatus() {
        let pairs: [(ErikaUpscalerBackendStatus, PlaybackUpscalerState.Backend)] = [
            (ErikaUpscalerBackendStatus_Off, .off),
            (ErikaUpscalerBackendStatus_Inactive, .inactive),
            (ErikaUpscalerBackendStatus_Building, .building),
            (ErikaUpscalerBackendStatus_Scalar, .scalar),
            (ErikaUpscalerBackendStatus_SimdgroupMatrix, .simdgroupMatrix),
        ]
        for (raw, expected) in pairs {
            #expect(PlaybackUpscalerState.Backend(Int32(raw.rawValue)) == expected)
        }
        #expect(PlaybackUpscalerState.Backend(42) == .unknown)
    }

    @Test("状态字段原样映射")
    func mapsStatusFields() {
        var raw = ErikaUpscalerStatus()
        raw.requested_mode = Int32(ErikaLumaUpscalerMode_ArtCnnC4F16Ds.rawValue)
        raw.active_backend = Int32(ErikaUpscalerBackendStatus_SimdgroupMatrix.rawValue)
        raw.fallback_count = 2
        raw.upscaled_frames = 1_234

        let state = PlaybackUpscalerState(raw)
        #expect(state.requested == .artCnnC4F16Ds)
        #expect(state.backend == .simdgroupMatrix)
        #expect(state.fallbackCount == 2)
        #expect(state.upscaledFrames == 1_234)
        #expect(!state.isFallingBackNatively, "有真后端时不该报回落")
    }

    @Test("请求了增强但后端 inactive 才算「已回落」")
    func fallingBackOnlyWhenRequestedAndInactive() {
        let inactive = PlaybackUpscalerState(
            requested: .artCnnC4F16, backend: .inactive
        )
        #expect(inactive.isFallingBackNatively, "开关开着却没生效，UI 必须能提示")

        // 请求关闭时后端自然是 off/inactive，那不算回退。
        #expect(!PlaybackUpscalerState(requested: .off, backend: .off).isFallingBackNatively)
        #expect(!PlaybackUpscalerState(requested: .off, backend: .inactive).isFallingBackNatively)
        // 请求开着且后端在干活：正常。
        #expect(!PlaybackUpscalerState(
            requested: .artCnnC4F16, backend: .simdgroupMatrix).isFallingBackNatively)
    }

    @Test("中性值：请求关闭、后端 off")
    func neutralStateIsOff() {
        #expect(PlaybackUpscalerState.unknown.requested == .off)
        #expect(PlaybackUpscalerState.unknown.backend == .off)
        #expect(!PlaybackUpscalerState.unknown.isFallingBackNatively)
    }
}
