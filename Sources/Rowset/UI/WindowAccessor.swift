import AppKit
import SwiftUI

/// Sets up the window: it remembers its frame, it shows no title, it carries no toolbar, and its
/// title bar covers only the window buttons.
///
/// The setup runs more than once on purpose. AppKit builds the window in steps and undoes some of
/// this on the way, and it stretches the title bar again after every resize. One call at launch
/// held only until the next window event, which is why the sidebar sometimes took the window
/// buttons only after the first tab opened.
struct WindowAccessor: NSViewRepresentable {
    let autosaveName: String

    /// The least width the title bar may take. It must hold the three window buttons.
    static let minimumTitlebarWidth: CGFloat = 100

    /// When to set the window up again, in seconds after the view reaches a window.
    private static let setupDelays: [Double] = [0, 0.05, 0.2, 0.5, 1.0]

    /// When to narrow the title bar, in seconds after the view reaches a window.
    ///
    /// This waits on purpose. The split view reads the title bar while it lays the sidebar out,
    /// and a title bar that is already narrow at that moment leaves the sidebar below it instead
    /// of under the window buttons.
    private static let narrowDelays: [Double] = [0.8, 1.5, 2.5]

    func makeCoordinator() -> Coordinator { Coordinator(autosaveName: autosaveName) }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onWindowChange = { [coordinator = context.coordinator] window in
            coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        Coordinator.configure(window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Tells the coordinator when it has a window to work on.
    final class ProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private let autosaveName: String
        private var observers: [any NSObjectProtocol] = []
        private var didRestoreFrame = false

        init(autosaveName: String) {
            self.autosaveName = autosaveName
        }

        func attach(to window: NSWindow?) {
            detach()
            guard let window else { return }

            if !didRestoreFrame {
                didRestoreFrame = true
                // Restore first. Setting the autosave name writes the current frame at once.
                window.setFrameUsingName(autosaveName)
                window.setFrameAutosaveName(autosaveName)
                // Once only. Setting the toolbar forces a new title bar layout.
                if window.toolbar != nil { window.toolbar = nil }
            }

            // AppKit is not finished with the window yet, so ask again a few times.
            for delay in WindowAccessor.setupDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    guard let window else { return }
                    Self.configure(window)
                }
            }

            // The title bar comes last, once the sidebar has taken its place under it.
            for delay in WindowAccessor.narrowDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    guard let window else { return }
                    Self.configure(window)
                }
            }

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                let token = NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { note in
                    guard let changed = note.object as? NSWindow else { return }
                    MainActor.assumeIsolated { Self.configure(changed) }
                }
                observers.append(token)
            }

            // The title bar follows the sidebar while you drag the divider.
            let dividerToken = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated { Self.configure(window) }
            }
            observers.append(dividerToken)
        }

        func detach() {
            for token in observers { NotificationCenter.default.removeObserver(token) }
            observers.removeAll()
        }

        /// Takes away everything above the content.
        ///
        /// A measurement of the window showed 52 points reserved at the top. 32 of those were the
        /// title bar and 20 were an `NSToolbar` that the SwiftUI modifier hid but never removed.
        /// The menu bar already names the app, so the title text goes as well.
        /// Sets the window up. This runs on every window event, so it must change nothing that
        /// forces a new title bar layout.
        ///
        /// `window.toolbar = nil` did force one. It ran on every focus change, the title bar was
        /// laid out again, and the sidebar lost its full height. That is why the window buttons
        /// left the sidebar whenever the window came back to the front. The toolbar now goes once
        /// and only once, in `attach`.
        static func configure(_ window: NSWindow) {
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.title.isEmpty { window.title = "" }
            if window.titlebarSeparatorStyle != .none {
                window.titlebarSeparatorStyle = .none
            }

            askForFullHeightSidebar(in: window)
            // Again after this layout pass, in case something else asked for a new one.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                askForFullHeightSidebar(in: window)
            }
        }

        /// Tells the split view that the sidebar runs the full height of the window.
        ///
        /// That flag is what puts the window buttons on the sidebar. SwiftUI sets it by itself,
        /// but not on every path, which is why the buttons were there only some of the time.
        private static func askForFullHeightSidebar(in window: NSWindow) {
            guard let controller = splitViewController(in: window),
                  let sidebar = controller.splitViewItems.first
            else { return }
            if !sidebar.allowsFullHeightLayout { sidebar.allowsFullHeightLayout = true }
            if sidebar.titlebarSeparatorStyle != .none {
                sidebar.titlebarSeparatorStyle = .none
            }
        }

        private static func splitViewController(in window: NSWindow) -> NSSplitViewController? {
            guard let root = window.contentViewController else { return nil }
            var queue: [NSViewController] = [root]
            while !queue.isEmpty {
                let controller = queue.removeFirst()
                if let split = controller as? NSSplitViewController { return split }
                queue.append(contentsOf: controller.children)
            }
            return nil
        }

    }
}
