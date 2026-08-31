import AppKit
import SwiftUI

/// Puts the tab bar inside the window title bar.
///
/// The earlier way cut `NSTitlebarContainerView` down to the sidebar width. That worked only
/// until AppKit laid the window out again, so the window buttons came and went and the tabs took
/// clicks only some of the time.
///
/// A titlebar accessory is the supported way to put a control up there. AppKit owns the layout,
/// the accessory takes its own clicks, and nothing has to fight anything.
struct TitlebarTabBar: NSViewRepresentable {
    let model: AppModel

    /// The height of the title bar row.
    static let height: CGFloat = 28

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onWindowChange = { [coordinator = context.coordinator] window in
            coordinator.install(in: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.resize()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class ProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private let model: AppModel
        private weak var window: NSWindow?
        private var controller: NSTitlebarAccessoryViewController?
        private var container: NSView?
        private var observers: [any NSObjectProtocol] = []

        init(model: AppModel) {
            self.model = model
        }

        func install(in window: NSWindow?) {
            remove()
            guard let window else { return }
            self.window = window

            let hosting = NSHostingView(rootView: TabBarView(model: model))
            hosting.autoresizingMask = [.width, .height]

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: TitlebarTabBar.height))
            container.addSubview(hosting)
            hosting.frame = container.bounds
            self.container = container

            let controller = NSTitlebarAccessoryViewController()
            controller.view = container
            // The right side of the title bar, which is the part beside the sidebar.
            controller.layoutAttribute = .right
            window.addTitlebarAccessoryViewController(controller)
            self.controller = controller

            observe(window)
            resize()
        }

        func remove() {
            for token in observers { NotificationCenter.default.removeObserver(token) }
            observers.removeAll()

            if let window, let controller,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: controller) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            controller = nil
            container = nil
            window = nil
        }

        /// Gives the accessory the width between the sidebar and the right edge.
        func resize() {
            guard let window, let container else { return }
            let sidebar = Self.sidebarWidth(in: window) ?? 0
            let width = max(120, window.frame.width - sidebar)
            guard abs(container.frame.width - width) > 0.5 else { return }
            container.setFrameSize(NSSize(width: width, height: TitlebarTabBar.height))
        }

        private func observe(_ window: NSWindow) {
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resize() }
                })
            }

            // The accessory follows the sidebar while you drag the divider.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resize() }
            })
        }

        /// The width of the first column of the split view that holds the sidebar.
        private static func sidebarWidth(in window: NSWindow) -> CGFloat? {
            guard let root = window.contentView else { return nil }
            var queue: [NSView] = [root]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let split = view as? NSSplitView, split.isVertical,
                   split.arrangedSubviews.count >= 2 {
                    return split.arrangedSubviews[0].frame.width
                }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
    }
}
