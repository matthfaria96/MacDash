import AppKit
import SwiftUI
import Combine

/// Captures SwiftUI's `openWindow` action so AppKit surfaces (the menu-bar
/// popover, which lives outside the scene graph and has no working `openWindow`
/// environment) can reopen the main window after it has been closed. The main
/// window records the action on appear; the closure stays valid for the app's
/// lifetime even once the window is gone.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: ((String) -> Void)?
    weak var mainWindow: NSWindow?

    func showMainWindow() {
        if let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            open?("main")
        }
    }
    private init() {}
}

/// A borderless panel that keeps its top edge where it was put, so content
/// that grows pushes the bottom down instead of the top up.
final class MenuBarPanel: NSPanel {
    var topEdge: CGFloat?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let topEdge { frame.origin.y = topEdge - frame.height }
        super.setFrame(frame, display: flag)
    }

}

/// The MacFresh menu bar item: its icon and, if chosen in Settings, a light
/// live readout. Clicking it opens a panel with the Mac's health, storage,
/// memory, battery, CPU, network and connected devices; a card's "Details"
/// link unfolds the detail under that card, and the panel grows downward
/// to fit, then shrinks back when it's closed. Built on `NSStatusItem` and an
/// `NSPanel` rather than `MenuBarExtra`, which can't animate its own height
/// and stalls the XCTest host.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let model = MenuBarModel.shared
    private let state = MenuBarPanelState()
    private let panel = MenuBarPanel()
    private var contentHeight: CGFloat = 0
    /// Until the panel has settled after opening, height changes snap
    /// instead of animating, so it never visibly grows into place.
    private var settling = false
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private let readout = MenuBarReadoutSampler()
    private let icon = MenuBarController.statusImage()
    private var readoutSignature = ""

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Persist the user's show/hide choice and ensure the item is requested
        // visible (it defaults hidden when restored from a prior autosave state).
        statusItem.autosaveName = "MacTidySystemMonitor"
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.image = icon
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("MacFresh")
        }

        let close: () -> Void = { [weak self] in self?.closePanels() }
        let content = NSHostingController(rootView: MenuBarPanelView(
            model: model,
            state: state,
            close: close,
            onHeightChange: { [weak self] height in self?.fit(height: height) }
        ))
        // The controller sizes the window itself, so the height can animate.
        content.sizingOptions = []
        content.view.wantsLayer = true
        content.view.layer?.backgroundColor = .clear
        panel.contentViewController = content

        state.$detail
            .removeDuplicates()
            .sink { [weak self] detail in self?.model.openDetail = detail }
            .store(in: &cancellables)

        readout.onUpdate = { [weak self] values in self?.drawReadout(values) }
        applyReadoutPreferences()
        // Settings writes straight to UserDefaults; pick up readout changes.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyReadoutPreferences() }
            .store(in: &cancellables)
    }

    /// Starts, stops or reshapes the readout to match Settings. Only the
    /// metrics shown are ever read.
    private func applyReadoutPreferences() {
        let metrics = MenuBarPreferences.metrics
        let signature = "\(metrics)|\(MenuBarPreferences.style)|\(MenuBarPreferences.interval)|\(MenuBarPreferences.alertColors)|\(MenuBarPreferences.showIcon)"
        guard signature != readoutSignature else { return }
        readoutSignature = signature
        readout.configure(metrics: metrics, interval: MenuBarPreferences.interval)
        drawReadout(readout.values)
    }

    private func drawReadout(_ values: MenuBarReadoutValues) {
        guard let button = statusItem.button else { return }
        let metrics = MenuBarPreferences.metrics
        // The icon always shows when there's nothing else to click on.
        let showIcon = MenuBarPreferences.showIcon || metrics.isEmpty
        if metrics.isEmpty {
            button.image = icon
            return
        }
        button.image = MenuBarReadoutRenderer.image(
            values: values,
            metrics: metrics,
            style: MenuBarPreferences.style,
            alerts: MenuBarPreferences.alertColors,
            icon: showIcon ? icon : nil
        )
    }

    /// Remove the status item. Called by AppDelegate before dropping the
    /// controller so teardown runs on the main actor.
    func teardown() {
        readout.stop()
        closePanels()
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// The menu bar glyph: a monitor with a sparkle, drawn as a template so it
    /// follows the menu bar's light and dark appearance.
    private static func statusImage() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            if let monitor = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let frame = NSRect(x: 0, y: (rect.height - monitor.size.height) / 2, width: monitor.size.width, height: monitor.size.height)
                monitor.draw(in: frame)
            }
            let sparkleConfiguration = NSImage.SymbolConfiguration(pointSize: 7.5, weight: .bold)
            if let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(sparkleConfiguration) {
                sparkle.draw(in: NSRect(x: rect.width - sparkle.size.width, y: rect.height - sparkle.size.height, width: sparkle.size.width, height: sparkle.size.height))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacFresh"
        return image
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if panel.isVisible {
            closePanels()
        } else {
            openPanel()
        }
    }

    private func showMenu() {
        closePanels()
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open MacFresh"), action: #selector(openApp), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit MacFresh"), action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    #if DEBUG
    /// Debug builds only: `-DebugMenuBarPanel memory` opens the panel and that
    /// card's detail, so screenshots don't need clicks.
    func debugOpen(_ detail: String) {
        openPanel()
        if let tile = MenuBarDetail(rawValue: detail) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.state.show(tile)
            }
        }
    }
    #endif

    @objc private func openApp() { MenuBarNavigation.open() }
    @objc private func openSettings() { MenuBarNavigation.open(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        model.start()
        state.reset()
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let width = MenuBarStyle.panelWidth
        let fitting = panel.contentViewController?.view.fittingSize.height ?? 0
        let height = min(max(contentHeight, fitting, 300), availableHeight(below: anchor.minY - 6, in: visible))
        var x = anchor.midX - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        let top = anchor.minY - 6
        panel.topEdge = top
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
        panel.alphaValue = 0
        settling = true
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.settling = false
        }
        button.highlight(true)
        installMonitors()
    }

    private func availableHeight(below top: CGFloat, in visible: NSRect) -> CGFloat {
        max(200, top - visible.minY - 12)
    }

    /// Follows the content's height: the window grows downward as a detail
    /// unfolds and shrinks back as it folds, never past the bottom of the
    /// screen (the panel scrolls instead).
    private func fit(height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        guard panel.isVisible, let top = panel.topEdge else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let target = min(height, availableHeight(below: top, in: visible))
        guard abs(target - panel.frame.height) > 0.5 else { return }
        let frame = NSRect(x: panel.frame.minX, y: top - target, width: panel.frame.width, height: target)
        guard !settling else {
            panel.setFrame(frame, display: true)
            return
        }
        // Animated by Core Animation, so it never blocks the main thread the
        // way `setFrame(_:display:animate:)` does, and the content's own
        // animation keeps running alongside.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func closePanels() {
        guard panel.isVisible else { return }
        removeMonitors()
        state.reset()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            }
        })
        statusItem.button?.highlight(false)
        model.stop()
    }

    /// Clicks outside the panel close it, as a menu would; Escape too.
    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.closePanels() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                // Escape folds an open detail first, then closes the panel.
                if self.state.detail != nil {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { self.state.reset() }
                } else {
                    self.closePanels()
                }
                return nil
            }
            // Confirmations shown from the panel (emptying the Trash, force
            // quitting) are sheets of it; clicks there count as inside.
            let window = event.window
            let inside = window === self.panel
                || window?.sheetParent === self.panel
                || window?.parent === self.panel
                || window === self.statusItem.button?.window
            if !inside { self.closePanels() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}
