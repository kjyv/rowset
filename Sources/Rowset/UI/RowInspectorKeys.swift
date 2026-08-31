import AppKit
import SwiftUI

/// Gives the space bar and the arrow keys to the row view, whatever holds the keyboard.
///
/// A value in that view can be selected, and a click puts the text of it in charge of the
/// keyboard. A text view swallows a space and an arrow before any shortcut sees them, which is
/// why the keys worked until the first click and not after it.
///
/// A read only value has no use for those keys, so the window takes them first.
struct RowInspectorKeys: NSViewRepresentable {
    let onSpace: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSpace: onSpace, onUp: onUp, onDown: onDown)
    }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onWindowChange = { [coordinator = context.coordinator] probe in
            coordinator.install(in: probe.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSpace = onSpace
        context.coordinator.onUp = onUp
        context.coordinator.onDown = onDown
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
        var onSpace: () -> Void
        var onUp: () -> Void
        var onDown: () -> Void

        private weak var sheet: NSWindow?
        private var monitor: Any?

        init(onSpace: @escaping () -> Void, onUp: @escaping () -> Void, onDown: @escaping () -> Void) {
            self.onSpace = onSpace
            self.onUp = onUp
            self.onDown = onDown
        }

        func install(in window: NSWindow?) {
            sheet = window
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // `NSEvent` is not `Sendable`, so the isolated part answers with a flag only.
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let sheet = self.sheet, sheet.isKeyWindow,
                          event.modifierFlags
                            .intersection(.deviceIndependentFlagsMask).isEmpty
                    else { return false }

                    switch event.keyCode {
                    case 49: self.onSpace()
                    case 126: self.onUp()
                    case 125: self.onDown()
                    default: return false
                    }
                    return true
                }
                return handled ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            sheet = nil
        }
    }
}
