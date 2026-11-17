import SwiftUI

#if os(iOS)
import UIKit

/// Let the navigation transition own the tab bar's movement, including a cancelled pop.
/// A destination's SwiftUI toolbar preference can otherwise outlive its return animation.
struct DetailTabBarVisibility: UIViewControllerRepresentable {
    let isHidden: Bool

    func makeUIViewController(context: Context) -> DetailTabBarVisibilityController {
        let controller = DetailTabBarVisibilityController()
        controller.isHidden = isHidden
        return controller
    }

    func updateUIViewController(_ controller: DetailTabBarVisibilityController, context: Context) {
        controller.isHidden = isHidden
        controller.apply()
    }
}

final class DetailTabBarVisibilityController: UIViewController {
    var isHidden = false
    private var entryVisibility: Bool?

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        apply()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyFlag()
        guard let page = navigationPage(), let tab = page.tabBarController else { return }
        if entryVisibility == nil { entryVisibility = tab.isTabBarHidden }
        changeVisibility(isHidden, page: page, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let page = navigationPage(), page.isMovingFromParent else { return }
        let destination = page.transitionCoordinator?.viewController(forKey: .to)
        changeVisibility(destination?.hidesBottomBarWhenPushed ?? entryVisibility ?? false,
                         page: page, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        apply()
    }

    func apply() {
        applyFlag()
        guard let page = navigationPage(), page.navigationController?.topViewController === page,
              viewIfLoaded?.window != nil, page.transitionCoordinator == nil else { return }
        page.tabBarController?.setTabBarHidden(isHidden, animated: false)
    }

    private func navigationPage() -> UIViewController? {
        var page: UIViewController = self
        while let parent = page.parent, !(parent is UINavigationController) { page = parent }
        return page.parent is UINavigationController ? page : nil
    }

    private func applyFlag() {
        guard let page = navigationPage() else { return }
        if page.hidesBottomBarWhenPushed != isHidden { page.hidesBottomBarWhenPushed = isHidden }
    }

    private func changeVisibility(_ hidden: Bool, page: UIViewController, animated: Bool) {
        guard let tab = page.tabBarController else { return }
        // SwiftUI wraps NavigationStack in a tab hosting controller. That extra wrapper
        // means hidesBottomBarWhenPushed alone doesn't always reach UITabBarController.
        if let coordinator = page.transitionCoordinator, coordinator.isAnimated {
            let registered = coordinator.animate(alongsideTransition: { [weak tab] _ in
                if tab?.isTabBarHidden != hidden { tab?.setTabBarHidden(hidden, animated: true) }
            }, completion: { [weak tab] context in
                guard context.isCancelled else { return }
                let originalPage = context.viewController(forKey: .from)
                tab?.setTabBarHidden(originalPage?.hidesBottomBarWhenPushed ?? !hidden, animated: false)
            })
            if registered { return }
        }
        if tab.isTabBarHidden != hidden { tab.setTabBarHidden(hidden, animated: animated) }
    }

}
#endif

extension View {
    func navigationTabBarHidden(_ isHidden: Bool) -> some View {
        #if os(iOS)
        background { DetailTabBarVisibility(isHidden: isHidden).allowsHitTesting(false) }
        #else
        self
        #endif
    }
}
