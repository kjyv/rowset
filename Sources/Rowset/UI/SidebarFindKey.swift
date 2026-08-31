import AppKit
import SwiftUI

/// Sends Command-F to the filter field while the sidebar has the keyboard.
///
/// A shortcut of its own would take Command-F from every editor in the window, and both the SQL
/// editor and the value pane use it for their find bar. A key monitor asks first whether the
/// keyboard is in the sidebar, so the key belongs to the sidebar only while you are in it.
struct SidebarFindKey: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onWindowChange = { [coordinator = context.coordinator] probe in
            coordinator.install(near: probe)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class ProbeView: NSView {
        var onWindowChange: ((NSView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            onWindowChange?(self)
        }
    }

    @MainActor
    final class Coordinator {
        var action: () -> Void
        private weak var probe: NSView?
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func install(near probe: NSView) {
            self.probe = probe
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // `NSEvent` is not `Sendable`, so the isolated part answers with a flag only.
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let probe = self.probe,
                          let window = probe.window, window.isKeyWindow,
                          event.charactersIgnoringModifiers?.lowercased() == "f",
                          event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          Self.keyboardIsInSidebar(of: window, near: probe)
                    else { return false }

                    self.action()
                    return true
                }
                return handled ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the first responder sits inside the sidebar.
        private static func keyboardIsInSidebar(of window: NSWindow, near probe: NSView) -> Bool {
            guard let responder = window.firstResponder as? NSView,
                  let sidebar = sidebarRoot(of: probe)
            else { return false }
            return responder === sidebar || responder.isDescendant(of: sidebar)
        }

        /// The view that holds the whole sidebar, taken from the probe that lives in it.
        private static func sidebarRoot(of probe: NSView) -> NSView? {
            var view: NSView? = probe.superview
            var level = 0
            while let current = view, level < 6 {
                if current.subviews.contains(where: { $0 is NSScrollView }) { return current }
                view = current.superview
                level += 1
            }
            return probe.superview
        }
    }
}
