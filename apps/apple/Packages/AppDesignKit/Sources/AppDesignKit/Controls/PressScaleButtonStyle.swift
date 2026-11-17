import SwiftUI

/// 按压反馈的统一 ButtonStyle：按下时轻缩 + 降透明度（0.94 / 0.8，`Motion.fast` 回弹）。
///
/// 全站按压缩放只此一档——此前 HUD 里三套私有实现各写了一个缩放值
/// （0.92 / 0.95 / 0.94），视觉差异为零却各自维护。需要别的反馈语义的
/// （如悬停抬升）走 `hoverLift`，不要再来这里加档位。
public struct PressScaleButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .motion(Motion.fast, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == PressScaleButtonStyle {
    /// 按压轻缩反馈：`.buttonStyle(.pressScale)`。
    static var pressScale: PressScaleButtonStyle { PressScaleButtonStyle() }
}
