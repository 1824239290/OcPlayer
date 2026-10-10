import CErika
import Foundation
import PlaybackKit

// `SubtitleStyle` / `SubtitleStyleOverrides` → `ErikaSubtitleStyle` 的纯映射。
//
// 两件事必须一起做对才不出洋相：
// ① **nil 字段要传内核的「不覆盖」值**（0 / false / 默认），不能传“看起来合理”的
//    数字——内核是按字段读的，随便传个 0 会把字号变成 8、边距变成 0（字幕贴边）；
// ② **override_mask 默认 0**：不覆盖时这些值只用来填脚本没指定的部分，片源自带的
//    ASS 排版与特效字体全部保留。位只按用户显式改过的项置起来。
//
// 纯函数、不碰句柄，所以可以在无 GPU 的机器上单测（CI 可跑）——这块「传错字段」
// 的代价是画面上看不出原因的字幕错位，靠肉眼回归成本极高。

extension SubtitleStyleOverrides {
    /// 中立位 → 内核 `ERIKA_SUBTITLE_OVERRIDE_*` 宏。
    ///
    /// 逐位显式映射（宏的编号不是连续的：FONT_SIZE_FIELDS=2、FONT_NAME=3、COLORS=4、
    /// ATTRIBUTES=5、BORDER=6、ALIGNMENT=7、MARGINS=8、BLUR=11），所以**绝不能**
    /// 用位序对齐。
    public var erikaMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.colors) { mask |= ERIKA_SUBTITLE_OVERRIDE_COLORS }
        if contains(.attributes) { mask |= ERIKA_SUBTITLE_OVERRIDE_ATTRIBUTES }
        if contains(.border) { mask |= ERIKA_SUBTITLE_OVERRIDE_BORDER }
        if contains(.alignment) { mask |= ERIKA_SUBTITLE_OVERRIDE_ALIGNMENT }
        if contains(.margins) { mask |= ERIKA_SUBTITLE_OVERRIDE_MARGINS }
        return mask
    }
}

extension ErikaSubtitleStyle {
    /// 由中立的 `SubtitleStyle` 构造。
    ///
    /// 未设置的字段一律填**内核的默认值**（`erika.h` 的文档口径：字号 48、描边 2、
    /// 白色正文 + 半透明黑描边、bottom-centre 对齐），而不是 0——它们在不覆盖时
    /// 会参与「填充脚本空缺」，在覆盖时也只作用于用户改过的位。
    init(_ style: SubtitleStyle, overrides: SubtitleStyleOverrides) {
        self.init()
        primary_color_rgba = style.primaryColorRGBA ?? 0xFFFF_FFFF
        outline_color_rgba = style.outlineColorRGBA ?? 0x0000_007F
        font_size = 48
        outline_width = style.outlineWidth ?? 2
        bold = style.bold ?? false
        italic = false
        underline = false
        strike_out = false
        spacing = 0
        scale_x_percent = 100
        scale_y_percent = 100
        // 1 = 描边 + 阴影（内核默认），3 = 不透明底框。本仓库不暴露该项，
        // 覆盖时也只会在 BORDER 位置位的情况下被读。
        border_style = 1
        shadow_depth = 0
        blur = 0
        // 2 = 底部居中（numpad 布局），与内核默认一致。
        alignment = Int32(style.alignment ?? 2)
        margin_left = Int32(style.marginLeft ?? 0)
        margin_right = Int32(style.marginRight ?? 0)
        margin_vertical = Int32(style.marginVertical ?? 0)
        // 字体名 / 字体文件保持 NULL：本仓库暂时不开放字体选择，
        // 且 FONT_NAME 位不在 mask 里，不会误伤 ASS 自带字体。
        font_family = nil
        font_file_path = nil
        override_mask = overrides.erikaMask
    }
}
