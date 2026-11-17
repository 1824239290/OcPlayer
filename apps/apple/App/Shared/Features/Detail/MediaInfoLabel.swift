import AppDesignKit
import Foundation

/// 详情页「媒体信息」区块的格式化工具：服务端元数据 → 人读文本。
///
/// 与播放器 HUD 的 `PlayerVideoColorLabel` 是**两套语义**，不能互相复用：
/// 那个吃的是内核解码后的事件值（AVCol 数字码、transfer=16 表示 PQ），
/// 这里吃的是服务端在文件里读到的**字符串**（"smpte2084"、"bt2020nc"）。
/// 认不出的值一律回原始串，宁可显示 "foo" 也不猜错。
enum MediaInfoLabel {

    /// 码率：≥1 Mbps 走小数，其余走 kbps。
    static func bitrate(_ bitsPerSecond: Int?) -> String? {
        guard let bitsPerSecond, bitsPerSecond > 0 else { return nil }
        if bitsPerSecond >= 1_000_000 {
            let mbps = Double(bitsPerSecond) / 1_000_000
            return "\(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps"
        }
        return "\(bitsPerSecond / 1_000) kbps"
    }

    /// 文件大小。`ByteCountFormatter` 与设置页缓存体积同一口径。
    static func size(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// 帧率：23.976 这类小数保留三位，整数帧率不带小数点。
    static func frameRate(_ fps: Double?) -> String? {
        guard let fps, fps > 0 else { return nil }
        let value = fps.formatted(.number.precision(.fractionLength(fps == fps.rounded() ? 0 : 3)))
        return "\(value) fps"
    }

    /// 分辨率：`3840×2160 · 16:9`。宽高比复用播放器 HUD 的约分实现，两处口径一致。
    static func resolution(width: Int?, height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height) · \(PlayerVideoColorLabel.aspect(width: width, height: height))"
    }

    /// 声道：优先服务端给的布局名（"5.1"），补上实际声道数；没有布局只报声道数。
    static func channels(count: Int?, layout: String?) -> String? {
        let layout = layout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let count = count.flatMap { $0 > 0 ? $0 : nil }
        switch (layout.isEmpty, count) {
        case (false, let count?): return "\(layout) (\(count)ch)"
        case (false, nil): return layout
        case (true, let count?): return "\(count)ch"
        case (true, nil): return nil
        }
    }

    /// 采样率：44100 → "44.1 kHz"、48000 → "48 kHz"。
    static func sampleRate(_ hertz: Int?) -> String? {
        guard let hertz, hertz > 0 else { return nil }
        let khz = Double(hertz) / 1000
        return "\(khz.formatted(.number.precision(.fractionLength(khz == khz.rounded() ? 0 : 1)))) kHz"
    }

    /// 动态范围：服务端的 `VideoRangeType` 原始串 → 可读标签。
    /// DOVI 前缀（含 DOVIWithHDR10/HLG/SDR/EL 等变体）统一归「杜比视界」——
    /// 与 `PlaybackSessionContext.isDolbyVision` 的判定口径一致。
    static func dynamicRange(videoRangeType: String?) -> String? {
        guard let raw = trimmed(videoRangeType) else { return nil }
        let upper = raw.uppercased()
        if upper.hasPrefix("DOVI") { return "杜比视界" }
        switch upper {
        case "SDR": return "SDR"
        case "HDR10": return "HDR10"
        case "HDR10PLUS", "HDR10+": return "HDR10+"
        case "HLG": return "HLG"
        case "HDR": return "HDR"
        case "UNKNOWN": return nil
        default: return raw
        }
    }

    /// 色彩原色：FFmpeg 侧的名字 → 人读标准名；认不出的回原始串（不猜）。
    static func colorPrimaries(_ raw: String?) -> String? {
        guard let raw = trimmed(raw) else { return nil }
        switch raw.lowercased() {
        case "bt709": return "BT.709"
        case "bt470bg", "bt601": return "BT.601"
        case "bt2020", "bt2020nc", "bt2020c": return "BT.2020"
        case "smpte431": return "DCI-P3"
        case "smpte432": return "Display P3"
        default: return raw
        }
    }

    /// 传输函数：PQ / HLG 是 HDR 的两个关键值；认不出的回原始串。
    static func colorTransfer(_ raw: String?) -> String? {
        guard let raw = trimmed(raw) else { return nil }
        switch raw.lowercased() {
        case "smpte2084": return "PQ"
        case "arib-std-b67": return "HLG"
        case "bt709": return "BT.709"
        case "bt470bg", "bt601": return "BT.601"
        case "iec61966-2-1", "srgb": return "sRGB"
        case "bt2020-10", "bt2020-12": return "BT.2020"
        default: return raw
        }
    }

    /// 语言代码 → 本地化语言名（"zh" → "中文"）。认不出回原串。
    static func language(_ code: String?) -> String? {
        guard let code = trimmed(code) else { return nil }
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        // 先按完整 tag 试（zh-Hans / pt-BR），再退到主语言（zh）。
        if let name = Locale.current.localizedString(forIdentifier: normalized) { return name }
        let primary = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return Locale.current.localizedString(forLanguageCode: primary) ?? code
    }

    /// 编码名统一大写（hevc → HEVC）；"subrip" 这类显示名照旧。
    static func codec(_ raw: String?) -> String? {
        trimmed(raw)?.uppercased()
    }

    /// 容器格式统一大写（mkv → MKV）。与编码同理，只是读起来更整齐。
    static func container(_ raw: String?) -> String? {
        codec(raw)
    }

    /// 时长：秒 → 「1 小时 27 分」，与详情页其它时长同一口径。
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return RuntimeText.format(seconds)
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw
    }
}
