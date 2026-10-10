import CErika
import PlaybackKit

// `ErikaLumaUpscalerMode` / `ErikaUpscalerStatus` ↔ PlaybackKit 的中立类型。
//
// 纯映射（不碰句柄），所以能在无 GPU 的机器上单测——这正是重点：档位与 C 枚举的
// 对应关系一旦错位，用户选「F16 去噪」而内核跑的是别的档，画面上的差别又不足以
// 让人一眼看出选错了。

extension PlaybackUpscalerMode {
    /// 中立档位 → 内核枚举。**逐个显式写出**，不用 `rawValue` 直接互转：
    /// 两边枚举的成员顺序是各自独立演进的，靠 rawValue 对齐等于把两份枚举绑死。
    var erikaValue: ErikaLumaUpscalerMode {
        switch self {
        case .off: ErikaLumaUpscalerMode_Off
        case .artCnnC4F16: ErikaLumaUpscalerMode_ArtCnnC4F16
        case .artCnnC4F32: ErikaLumaUpscalerMode_ArtCnnC4F32
        case .artCnnC4F16Ds: ErikaLumaUpscalerMode_ArtCnnC4F16Ds
        }
    }

    init(_ raw: Int32) {
        switch raw {
        case Int32(ErikaLumaUpscalerMode_ArtCnnC4F16.rawValue): self = .artCnnC4F16
        case Int32(ErikaLumaUpscalerMode_ArtCnnC4F32.rawValue): self = .artCnnC4F32
        case Int32(ErikaLumaUpscalerMode_ArtCnnC4F16Ds.rawValue): self = .artCnnC4F16Ds
        default: self = .off
        }
    }
}

extension PlaybackUpscalerState.Backend {
    /// `ErikaUpscalerBackendStatus`（0…4）→ 中立枚举；未知值不猜。
    init(_ raw: Int32) {
        switch raw {
        case Int32(ErikaUpscalerBackendStatus_Off.rawValue): self = .off
        case Int32(ErikaUpscalerBackendStatus_Inactive.rawValue): self = .inactive
        case Int32(ErikaUpscalerBackendStatus_Building.rawValue): self = .building
        case Int32(ErikaUpscalerBackendStatus_Scalar.rawValue): self = .scalar
        case Int32(ErikaUpscalerBackendStatus_SimdgroupMatrix.rawValue): self = .simdgroupMatrix
        default: self = .unknown
        }
    }
}

extension PlaybackUpscalerState {
    init(_ raw: ErikaUpscalerStatus) {
        self.init(
            requested: PlaybackUpscalerMode(raw.requested_mode),
            backend: Backend(raw.active_backend),
            fallbackCount: raw.fallback_count,
            upscaledFrames: raw.upscaled_frames
        )
    }
}
