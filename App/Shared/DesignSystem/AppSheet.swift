import AppDesignKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// macOS sheet 共用 Bangumi 的半透明材质，iOS 保持系统背景；两端共用尺寸预算。表单可更短，列表保留滚动空间。
struct AppSheetSize {
    var minHeight: CGFloat
    var idealHeight: CGFloat
    var prefersCompactPresentation = true

    static let form = AppSheetSize(minHeight: 360, idealHeight: 440)
    static let search = AppSheetSize(minHeight: 520, idealHeight: 620, prefersCompactPresentation: false)
    static let subscription = AppSheetSize(minHeight: 520, idealHeight: 680, prefersCompactPresentation: false)
}

extension View {
    func appSheetSurface(size: AppSheetSize = .search) -> some View {
        modifier(AppSheetSurface(size: size))
    }
}

private struct AppSheetSurface: ViewModifier {
    let size: AppSheetSize
    #if os(macOS)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    #else
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesCompactPresentation: Bool {
        size.prefersCompactPresentation && !dynamicTypeSize.isAccessibilitySize
    }
    #endif

    func body(content: Content) -> some View {
        content
            .tint(AppAccent.tint)
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 560,
                   minHeight: size.minHeight, idealHeight: size.idealHeight)
            // 只替换系统 sheet 的底材质；圆角、边界与阴影仍由系统提供。
            .presentationBackground {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    ZStack {
                        AppSheetWindowMaterial()
                        // 与 Bangumi 原来的跨窗口模糊和明暗遮罩保持一致。
                        (colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.98))
                            .opacity(0.62)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            #else
            // iOS 使用系统默认背景，不注入 macOS 的半透明窗口材质。
            .presentationDetents(usesCompactPresentation ? [.height(size.idealHeight), .large] : [.large])
            .presentationDragIndicator(usesCompactPresentation ? .automatic : .hidden)
            #endif
    }
}

#if os(macOS)
/// 跨窗口采样才能透出 sheet 背后的页面；窗口内的 SwiftUI Material 只采到自身底色。
private struct AppSheetWindowMaterial: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> AppSheetEffectView {
        let view = AppSheetEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: AppSheetEffectView, context: Context) {
        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != appearance {
            view.appearance = NSAppearance(named: appearance)
        }
        view.prepareSheetWindow()
    }

    static func dismantleNSView(_ view: AppSheetEffectView, coordinator: ()) {
        view.stopUsingSheetWindow()
    }
}

private final class AppSheetEffectView: NSVisualEffectView {
    private weak var preparedWindow: NSWindow?
    private var originalBackground: NSColor?
    private var originalIsOpaque = true
    private var isActiveSurface = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if preparedWindow !== window { restoreSheetWindow() }
        // sheetParent 在视图挂载后才建立，下一次主队列核对实际呈现关系。
        DispatchQueue.main.async { [weak self] in self?.prepareSheetWindow() }
    }

    func prepareSheetWindow() {
        // 只处理本 sheet，不改父页面或普通 NSHostingView 的窗口。
        guard isActiveSurface, let window, window.sheetParent != nil else { return }
        if preparedWindow !== window {
            restoreSheetWindow()
            preparedWindow = window
            originalBackground = window.backgroundColor
            originalIsOpaque = window.isOpaque
        }
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    func stopUsingSheetWindow() {
        isActiveSurface = false
        restoreSheetWindow()
    }

    func restoreSheetWindow() {
        if let preparedWindow, let originalBackground {
            preparedWindow.backgroundColor = originalBackground
            preparedWindow.isOpaque = originalIsOpaque
        }
        preparedWindow = nil
        originalBackground = nil
    }
}
#endif

/// 标题与关闭按钮始终位于可滚动内容之外；多层选择器可提供返回动作。
struct AppSheetHeader: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    var canDismiss = true
    var onBack: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(AppSheetIconButtonStyle())
                    .accessibilityLabel("返回")
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(AppSheetIconButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(!canDismiss)
                .accessibilityLabel("关闭\(title)弹窗")
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }
}

struct AppSheetDivider: View {
    var body: some View {
        Divider().overlay(Color.primary.opacity(0.08)).opacity(0.3)
    }
}

/// 较窄或字体放大时把操作放到下一行，避免压缩标签或遮挡内容。
struct AppSheetFooter<Leading: View, Actions: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                leading()
                Spacer(minLength: 8)
                actions().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                leading()
                HStack { Spacer(minLength: 0); actions() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

struct AppSheetButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .foregroundStyle(primary && isEnabled ? AppAccent.onSolid : (isEnabled ? Color.primary : Color.secondary))
            .background(primary && isEnabled ? AppAccent.solid : Color.primary.opacity(0.04), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(primary ? 0 : 0.08), lineWidth: 0.5)
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct AppSheetIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            #if os(iOS)
            .frame(width: 44, height: 44)
            #else
            .frame(width: 30, height: 30)
            #endif
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0.04), in: Circle())
            .contentShape(Circle())
    }
}

struct AppSheetTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}

/// 长表单的字段分组；半透明底保持层级，不遮住窗口材质。
struct AppSheetSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.callout.weight(.medium))
            }
            VStack(alignment: .leading, spacing: 14) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
        }
    }
}
