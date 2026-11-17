import CErika
import PlaybackKit
import Testing
@testable import ErikaKit

/// `SubtitleStyle` → `ErikaSubtitleStyle` 的映射。
///
/// 这块传错的代价特别隐蔽：画面上只会表现为「字幕位置怪 / 颜色不对」，没有任何
/// 报错，肉眼回归又基本不会覆盖。两类错最要命——①把没设过的项传成 0（字幕直接
/// 贴到屏幕边上 / 字号被压成最小）；②`override_mask` 位序对齐（宏的编号不连续，
/// 位序对齐会让「只改颜色」变成「连边距一起替换」）。两条都逐项钉住。
/// 纯映射、不实例化 presenter，无 GPU 也能跑。
@Suite("字幕样式映射")
struct ErikaSubtitleStyleMappingTests {

    @Test("没设过的项一律用内核默认值，不能传 0")
    func unsetFieldsUseKernelDefaults() {
        let raw = ErikaSubtitleStyle(SubtitleStyle(), overrides: [])
        #expect(raw.font_size == 48, "字号传 0 会被内核钳成最小值 8")
        #expect(raw.outline_width == 2)
        #expect(raw.alignment == 2, "2 = 底部居中，是内核默认；传 0 是非法对齐")
        #expect(raw.primary_color_rgba == 0xFFFF_FFFF, "默认不透明白")
        #expect(raw.outline_color_rgba == 0x0000_007F, "默认半透明黑描边")
        #expect(raw.margin_left == 0)
        #expect(raw.margin_right == 0)
        #expect(raw.margin_vertical == 0)
        #expect(raw.bold == false)
        #expect(raw.font_family == nil, "字体名保持 NULL：本仓库不开放字体选择")
        #expect(raw.font_file_path == nil)
    }

    @Test("设过的项原样带上")
    func setFieldsAreForwarded() {
        let style = SubtitleStyle(
            alignment: 8,
            marginVertical: 40,
            marginLeft: 12,
            marginRight: 12,
            primaryColorRGBA: 0xFFCC_00FF,
            outlineColorRGBA: 0x0011_2288,
            outlineWidth: 4,
            bold: true
        )
        let raw = ErikaSubtitleStyle(style, overrides: [])
        #expect(raw.alignment == 8)
        #expect(raw.margin_vertical == 40)
        #expect(raw.margin_left == 12)
        #expect(raw.margin_right == 12)
        #expect(raw.primary_color_rgba == 0xFFCC_00FF)
        #expect(raw.outline_color_rgba == 0x0011_2288)
        #expect(raw.outline_width == 4)
        #expect(raw.bold)
    }

    @Test("默认不覆盖：override_mask 为 0（ASS 自带排版与特效字体保留）")
    func defaultMaskIsZero() {
        let style = SubtitleStyle(alignment: 2, primaryColorRGBA: 0xFF0000FF, bold: true)
        let raw = ErikaSubtitleStyle(style, overrides: [])
        #expect(raw.override_mask == 0)
        // 值照样带上（用于填空缺），只是不替换脚本自己的样式。
        #expect(raw.primary_color_rgba == 0xFF0000FF)
    }

    @Test("覆盖位逐个对齐内核宏（宏编号不连续，不能按位序对齐）")
    func overrideBitsMatchKernelMacros() {
        #expect(SubtitleStyleOverrides.colors.erikaMask == ERIKA_SUBTITLE_OVERRIDE_COLORS)
        #expect(SubtitleStyleOverrides.attributes.erikaMask == ERIKA_SUBTITLE_OVERRIDE_ATTRIBUTES)
        #expect(SubtitleStyleOverrides.border.erikaMask == ERIKA_SUBTITLE_OVERRIDE_BORDER)
        #expect(SubtitleStyleOverrides.alignment.erikaMask == ERIKA_SUBTITLE_OVERRIDE_ALIGNMENT)
        #expect(SubtitleStyleOverrides.margins.erikaMask == ERIKA_SUBTITLE_OVERRIDE_MARGINS)
    }

    @Test("all 恰好等于内核的 ERIKA_SUBTITLE_OVERRIDE_ALL 里本仓库涉及的那几位")
    func allMaskCoversExposedFieldsOnly() {
        let expected = ERIKA_SUBTITLE_OVERRIDE_COLORS
            | ERIKA_SUBTITLE_OVERRIDE_ATTRIBUTES
            | ERIKA_SUBTITLE_OVERRIDE_BORDER
            | ERIKA_SUBTITLE_OVERRIDE_ALIGNMENT
            | ERIKA_SUBTITLE_OVERRIDE_MARGINS
        #expect(SubtitleStyleOverrides.all.erikaMask == expected)
        // 字体名 / 字号字段 / 模糊这几位本仓库不透出，绝不能被 all 顺手带上。
        #expect(SubtitleStyleOverrides.all.erikaMask & ERIKA_SUBTITLE_OVERRIDE_FONT_NAME == 0)
        #expect(SubtitleStyleOverrides.all.erikaMask & ERIKA_SUBTITLE_OVERRIDE_FONT_SIZE_FIELDS == 0)
        #expect(SubtitleStyleOverrides.all.erikaMask & ERIKA_SUBTITLE_OVERRIDE_BLUR == 0)
    }

    @Test("组合位按位或，能同时替换多类字段")
    func combinedMaskIsUnion() {
        let mask: SubtitleStyleOverrides = [.colors, .margins]
        #expect(
            mask.erikaMask
                == (ERIKA_SUBTITLE_OVERRIDE_COLORS | ERIKA_SUBTITLE_OVERRIDE_MARGINS)
        )
    }

    @Test("covering 能识别出样式里改过哪几类（新增字段忘了归类会被报出来）")
    func coveringDetectsFamilies() {
        #expect(SubtitleStyleOverrides.covering(SubtitleStyle()) == [])
        #expect(SubtitleStyleOverrides.covering(
            SubtitleStyle(primaryColorRGBA: 0xFF0000FF)) == [.colors])
        #expect(SubtitleStyleOverrides.covering(SubtitleStyle(bold: false)) == [.attributes])
        #expect(SubtitleStyleOverrides.covering(SubtitleStyle(outlineWidth: 3)) == [.border])
        #expect(SubtitleStyleOverrides.covering(SubtitleStyle(alignment: 2)) == [.alignment])
        #expect(SubtitleStyleOverrides.covering(
            SubtitleStyle(marginVertical: 20)) == [.margins])
        // 全设一遍：应该正好覆盖 all 里本仓库涉及的全部类别。
        let everything = SubtitleStyle(
            alignment: 2, marginVertical: 10, marginLeft: 5, marginRight: 5,
            primaryColorRGBA: 0xFFFF_FFFF, outlineColorRGBA: 0x0000_007F,
            outlineWidth: 2, bold: true
        )
        #expect(SubtitleStyleOverrides.covering(everything) == .all)
    }

    @Test("空样式能自检：调用方据此跳过下发")
    func emptyStyleIsDetected() {
        #expect(SubtitleStyle().isEmpty)
        #expect(!SubtitleStyle(alignment: 2).isEmpty)
        #expect(!SubtitleStyle(bold: false).isEmpty, "明确关掉加粗也是一种设置")
        #expect(!SubtitleStyle(outlineWidth: 0.5).isEmpty)
    }
}
