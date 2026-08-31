import AppKit
import SwiftUI

/// Lets AppKit remember the window size and position.
///
/// AppKit stores the frame in `UserDefaults` under the autosave name and restores it at the next
/// launch. SwiftUI has no equivalent on macOS, so the view reaches the `NSWindow` directly.
struct WindowAccessor: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Restore first. Setting the autosave name writes the current frame at once.
            window.setFrameUsingName(autosaveName)
            window.setFrameAutosaveName(autosaveName)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
