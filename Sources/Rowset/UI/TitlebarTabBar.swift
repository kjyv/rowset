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
        // The sidebar animates open and shut, so measure again while it moves.
        context.coordinator.resizeAfterAnimation()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    /// Holds the bar, and keeps the title bar from taking the drag.
    ///
    /// A view in the title bar moves the window when you drag it, and the tab bar has its own
    /// use for a drag. The window still moves by the title bar beside the bar.
    final class TabBarContainerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    final class TabBarHostingView: NSHostingView<TabBarView> {
        override var mouseDownCanMoveWindow: Bool { false }
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

            let hosting = TabBarHostingView(rootView: TabBarView(model: model))
            hosting.autoresizingMask = [.width, .height]

            let container = TabBarContainerView(
                frame: NSRect(x: 0, y: 0, width: 600, height: TitlebarTabBar.height))
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

        /// Gives the accessory the width between the detail column and the right edge.
        func resize() {
            guard let window, let container else { return }
            let start = sidebarOffset(in: window)
            let width = max(120, window.frame.width - start)
            guard abs(container.frame.width - width) > 0.5 else { return }
            container.setFrameSize(NSSize(width: width, height: TitlebarTabBar.height))
        }

        /// Waits out the animation of the split view, then measures again.
        func resizeAfterAnimation() {
            resize()
            for delay in [0.1, 0.25, 0.45] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.resize()
                }
            }
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

        /// How much of the title bar the sidebar takes.
        ///
        /// This reads the width of the first column and not the position of the second. Both
        /// columns of this split view report an x of zero, so the position says nothing.
        ///
        /// A closed sidebar keeps its width, so the app also asks whether it is closed. Without
        /// that the tabs stayed offset and floated in the middle of the title bar.
        private func sidebarOffset(in window: NSWindow) -> CGFloat {
            let minimum = Self.roomForWindowControls(in: window)
            guard model.isSidebarVisible,
                  let split = Self.mainSplitView(in: window),
                  let sidebar = split.arrangedSubviews.first,
                  !split.isSubviewCollapsed(sidebar)
            else { return minimum }
            return max(sidebar.frame.width, minimum)
        }

        /// The space the window controls need at the left of the title bar.
        ///
        /// While the sidebar is open, its width covers them and this never applies. While it is
        /// closed, macOS puts the sidebar toggle in the title bar beside the window buttons, and
        /// a first tab at zero would sit under both.
        private static func roomForWindowControls(in window: NSWindow) -> CGFloat {
            let buttonsEnd = window.standardWindowButton(.zoomButton)?.frame.maxX ?? 78
            // Room for the sidebar toggle that macOS adds beside them.
            return buttonsEnd + 72
        }

        /// Finds the split view that divides the window left from right.
        ///
        /// The search skips the split views inside a tab, which divide top from bottom.
        private static func mainSplitView(in window: NSWindow) -> NSSplitView? {
            guard let root = window.contentView else { return nil }
            var queue: [NSView] = [root]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let split = view as? NSSplitView, split.isVertical,
                   split.arrangedSubviews.count >= 2 {
                    return split
                }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
    }
}
