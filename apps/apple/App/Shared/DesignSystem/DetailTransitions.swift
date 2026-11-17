import SwiftUI

/// A rendered card's identity, independent of the destination media ID.
struct DetailTransitionSource: Hashable {
    let section: AppModel.Section
    let list: String
    let instance: UUID
    let position: String
}

#if os(iOS)
struct DetailTransitionContext {
    let section: AppModel.Section
    let namespace: Namespace.ID
}

extension EnvironmentValues {
    @Entry var detailTransitionContext: DetailTransitionContext? = nil
}

private struct DetailTransitionScope: ViewModifier {
    @Namespace private var namespace
    let section: AppModel.Section

    func body(content: Content) -> some View {
        content.environment(\.detailTransitionContext,
                            DetailTransitionContext(section: section, namespace: namespace))
    }
}
#endif

/// Keeps the source attached to the actual card (including its loading placeholder).
/// Each rendered placement has its own stable identity, even for duplicate media.
struct DetailTransitionCard<Card: View>: View {
    @State private var instance = UUID()
    #if os(iOS)
    @Environment(\.detailTransitionContext) private var context
    #endif
    let list: String
    let position: String
    let action: (DetailTransitionSource?) -> Void
    @ViewBuilder let card: (@escaping () -> Void) -> Card

    var body: some View {
        #if os(iOS)
        if let context {
            let source = DetailTransitionSource(section: context.section, list: list,
                                                instance: instance, position: position)
            card { action(source) }
                .matchedTransitionSource(id: source, in: context.namespace)
        } else {
            card { action(nil) }
        }
        #else
        card { action(nil) }
        #endif
    }
}

private struct DetailZoomTransition: ViewModifier {
    #if os(iOS)
    @Environment(\.detailTransitionContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif
    let source: DetailTransitionSource?

    func body(content: Content) -> some View {
        #if os(iOS)
        if let source, let context, source.section == context.section, !reduceMotion {
            content.navigationTransition(.zoom(sourceID: source, in: context.namespace))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct DetailCoverSettlement: ViewModifier {
    @State private var entered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(iOS)
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat(1), trigger: entered) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                LinearKeyframe(1.05, duration: 0.15)
                LinearKeyframe(0.98, duration: 0.15)
                LinearKeyframe(1, duration: 0.15)
            }
            .onAppear { if !entered { entered = true } }
        }
        #else
        content
        #endif
    }
}

extension View {
    #if os(iOS)
    func detailTransitionScope(section: AppModel.Section) -> some View {
        modifier(DetailTransitionScope(section: section))
    }
    #endif

    func detailZoomTransition(source: DetailTransitionSource?) -> some View {
        modifier(DetailZoomTransition(source: source))
    }

    func detailCoverSettlement() -> some View {
        modifier(DetailCoverSettlement())
    }

}
