// Finder Sync extension: adds "Analyze with MacDash" to Finder's right-click menu.
// It only builds the menu; the analysis runs in MacDash, reached through a macdash:// link.
import AppKit
import FinderSync

final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // Every volume, so the item is there wherever Finder shows a folder.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard folder(for: menuKind) != nil else { return nil }
        let menu = NSMenu(title: "MacDash")
        let item = NSMenuItem(title: NSLocalizedString("Analyze with MacDash", comment: "Finder menu item"),
                              action: #selector(analyze(_:)), keyEquivalent: "")
        item.image = Self.menuIcon("stethoscope")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// One folder: the one right-clicked, or the window's folder when the click
    /// was on its background. Apps have their own "Uninstall with MacDash".
    private func folder(for menuKind: FIMenuKind) -> URL? {
        let controller = FIFinderSyncController.default()
        switch menuKind {
        case .contextualMenuForItems:
            guard let items = controller.selectedItemURLs(), items.count == 1, let url = items.first,
                  url.hasDirectoryPath, url.pathExtension.lowercased() != "app" else { return nil }
            return url
        case .contextualMenuForContainer:
            return controller.targetedURL()
        default:
            return nil
        }
    }

    @objc private func analyze(_ sender: AnyObject?) {
        let controller = FIFinderSyncController.default()
        let kindIsContainer = (controller.selectedItemURLs() ?? []).isEmpty
        guard let url = folder(for: kindIsContainer ? .contextualMenuForContainer : .contextualMenuForItems) else { return }
        var components = URLComponents()
        components.scheme = "macdash"
        components.host = "analyze"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        guard let link = components.url else { return }
        NSWorkspace.shared.open(link)
    }

    /// An outline symbol drawn like Finder's own items. Finder doesn't tint
    /// images from extensions, so the text color is resolved here for the
    /// current appearance, and the glyph sits on a fixed 16 pt canvas because
    /// Finder stretches menu images to fill the icon slot.
    private static func menuIcon(_ symbol: String) -> NSImage? {
        var color = NSColor.labelColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let side: CGFloat = 16, scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * scale), pixelsHigh: Int(side * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return glyph }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let size = glyph.size
        glyph.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
