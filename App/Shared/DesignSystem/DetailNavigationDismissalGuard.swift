import SwiftUI

#if os(iOS)
import UIKit

/// SwiftUI's zoom transition has no interactive-dismissal policy. While the detail
/// pager owns a pull-down, temporarily use the navigation controller's ordinary
/// transition instead. The leading-edge back gesture and back button remain native.
struct DetailNavigationDismissalGuard: UIViewControllerRepresentable {
    let isBlocked: Bool

    func makeUIViewController(context: Context) -> DetailNavigationDismissalController {
        let controller = DetailNavigationDismissalController()
        controller.isBlocked = isBlocked
        return controller
    }

    func updateUIViewController(_ controller: DetailNavigationDismissalController, context: Context) {
        controller.isBlocked = isBlocked
        controller.apply()
    }

    static func dismantleUIViewController(_ controller: DetailNavigationDismissalController, coordinator: ()) {
        controller.restore()
    }
}

final class DetailNavigationDismissalController: UIViewController {
    var isBlocked = false
    private weak var guardedPage: UIViewController?
    private var savedTransition: UIViewController.Transition?

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        apply()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // SwiftUI may commit its preferred transition after updating the bridge.
        apply()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        restore()
    }

    func apply() {
        guard isBlocked else {
            restore()
            return
        }
        var page: UIViewController = self
        while let parent = page.parent, !(parent is UINavigationController) {
            page = parent
        }
        guard let navigation = page.parent as? UINavigationController,
              navigation.topViewController === page else { return }
        if guardedPage !== page { restore() }
        if let transition = page.preferredTransition {
            guardedPage = page
            savedTransition = transition
            page.preferredTransition = nil
        }
    }

    func restore() {
        // Do not overwrite a transition installed by another destination/update.
        if let guardedPage, guardedPage.preferredTransition == nil {
            guardedPage.preferredTransition = savedTransition
        }
        guardedPage = nil
        savedTransition = nil
    }
}
#endif

extension View {
    func detailNavigationDismissalBlocked(_ isBlocked: Bool) -> some View {
        #if os(iOS)
        background {
            DetailNavigationDismissalGuard(isBlocked: isBlocked)
                .allowsHitTesting(false)
        }
        #else
        self
        #endif
    }
}
