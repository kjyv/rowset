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
            Self.hideTitle(of: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI writes the window title on its own passes, so one call at the start is not
        // enough. Every update asks again.
        guard let window = nsView.window else { return }
        Self.hideTitle(of: window)
    }

    /// Takes the title text away and keeps the content out of the title bar.
    ///
    /// The menu bar already names the app. Hiding the toolbar also turns on a full size content
    /// view, and the tab bar then paints its background up into the title bar.
    private static func hideTitle(of window: NSWindow) {
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.title.isEmpty { window.title = "" }
        if window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.remove(.fullSizeContentView)
        }
        if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false }
    }
}
