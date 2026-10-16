import SwiftUI
import AppKit

/// Zero-size helper that captures SwiftUI's `openWindow` action into
/// `WindowOpener.shared` when the main window appears, so the AppKit menu-bar
/// popover can reopen the window after it's been closed.
struct WindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { WindowOpener.shared.open = { id in openWindow(id: id) } }
            .background(MainWindowReference())
    }
}

private struct MainWindowReference: NSViewRepresentable {
    func makeNSView(context: Context) -> ReferenceView { ReferenceView() }
    func updateNSView(_ nsView: ReferenceView, context: Context) {}

    final class ReferenceView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowOpener.shared.mainWindow = window }
        }
    }
}

/// Drop-down panel hosted in the menu-bar `NSPopover` (via `NSHostingController`)
/// with live CPU / memory / disk meters and quick actions. Kept self-contained
/// so the menu bar surface stays decoupled from the main window's `AppState`.
