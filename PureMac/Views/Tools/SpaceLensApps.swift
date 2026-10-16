import AppKit
import SwiftUI

/// Apps view of Space Lens: every installed app with everything it keeps on
/// disk, as a map of apps and a list that opens into each app's parts.
struct SpaceLensAppsView: View {
    @ObservedObject var model: SpaceLensModel
    @EnvironmentObject private var appState: AppState
    @State private var expanded: String?
    @State private var hoveredApp: String?

    var body: some View {
        switch model.apps {
        case .idle:
            Color.clear.onAppear { model.loadApps() }
        case .loading(let done, let total, let name):
            loading(done: done, total: total, name: name)
        case .loaded(let apps):
            if apps.isEmpty {
                CardSurface(padding: 24, elevation: .standard) {
                    EmptyStateView("No Apps Found", systemImage: "square.stack.3d.up", description: "No app in your Applications folders takes more than 1 MB.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                content(apps)
            }
        }
    }

    // MARK: Loading

    private func loading(done: Int, total: Int, name: String) -> some View {
        CardSurface(padding: 24, elevation: .standard) {
            VStack(spacing: 12) {
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                    .tint(SectionPalette.spaceLens.accent)
                    .frame(maxWidth: 320)
                Text(total > 0
                     ? String(format: String(localized: "Measuring apps · %lld of %lld"), Int64(done), Int64(total))
                     : String(localized: "Finding installed apps…"))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Text(name.isEmpty ? " " : name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Results

    private func content(_ apps: [AppFootprint]) -> some View {
        let total = apps.reduce(Int64(0)) { $0 + $1.totalSize }
        let largest = apps.first?.totalSize ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            CardSurface(padding: 8, elevation: .standard) {
                AppsTreemap(apps: apps, hovered: $hoveredApp) { app in
                    withAnimation(MotionTokens.snappy) { expanded = expanded == app.id ? nil : app.id }
                }
            }
            .frame(height: 230)

            HStack(spacing: 12) {
                Text(String(format: String(localized: "%lld apps · %@"), Int64(apps.count),
                            ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 8)
                ForEach(PartStyle.legend, id: \.title) { style in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2.5).fill(style.color).frame(width: 9, height: 9)
                        Text(style.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 6)

            CardSurface(padding: 0, elevation: .standard) {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(apps) { app in
                                AppFootprintRow(
                                    model: model,
                                    app: app,
                                    largest: largest,
                                    isExpanded: expanded == app.id,
                                    isHovered: hoveredApp == app.id,
                                    toggle: { withAnimation(MotionTokens.snappy) { expanded = expanded == app.id ? nil : app.id } },
                                    uninstall: { appState.presentExternalUninstall(appPath: app.appURL.path) }
                                )
                                .id(app.id)
                                .onHover { inside in
                                    if inside { hoveredApp = app.id } else if hoveredApp == app.id { hoveredApp = nil }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: expanded) { id in
                        guard let id else { return }
                        withAnimation(MotionTokens.gentle) { scroller.scrollTo(id, anchor: .top) }
                    }
                }
            }
        }
    }
}

// MARK: - Part colors

private struct PartStyle {
    let title: String
    let color: Color

    static func of(_ kind: AppFootprint.PartKind) -> PartStyle {
        switch kind {
        case .bundle: return PartStyle(title: String(localized: "App"), color: Tint.blue)
        case .support: return PartStyle(title: String(localized: "App Support"), color: Tint.orange)
        case .caches: return PartStyle(title: String(localized: "Caches"), color: Tint.pink)
        case .containers: return PartStyle(title: String(localized: "Containers"), color: Tint.cyan)
        case .other: return PartStyle(title: String(localized: "Other"), color: Color(white: 0.62))
        case .extra(let label): return PartStyle(title: String(localized: String.LocalizationValue(label)), color: Tint.green)
        }
    }

    static let legend: [PartStyle] = [
        of(.bundle), of(.support), of(.caches), of(.containers), of(.other),
        PartStyle(title: String(localized: "Extra places"), color: Tint.green),
    ]
}

// MARK: - Treemap

private struct AppsTreemap: View {
    let apps: [AppFootprint]
    @Binding var hovered: String?
    let select: (AppFootprint) -> Void

    private static let limit = 40
    private static let palette: [Color] = [Tint.blue, Tint.purple, Tint.pink, Tint.orange, Tint.cyan, Tint.green, Tint.teal, Tint.yellow]

    var body: some View {
        GeometryReader { proxy in
            let shown = Array(apps.prefix(Self.limit))
            let frames = SquarifiedTreemap.layout(shown.map { Double($0.totalSize) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, app in
                    let rect = frames[index].insetBy(dx: 1.5, dy: 1.5)
                    if rect.width > 1, rect.height > 1 {
                        tile(app, index: index, size: rect.size)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
        }
    }

    private func tile(_ app: AppFootprint, index: Int, size: CGSize) -> some View {
        let color = Self.palette[index % Self.palette.count]
        let isHovered = hovered == app.id
        let radius = min(10, min(size.width, size.height) / 4)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let strength = max(0.45, 0.92 - Double(min(index, 12)) * 0.04)
        return shape
            .fill(LinearGradient(colors: [color.opacity(strength), color.opacity(strength * 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.fill(Color.white.opacity(isHovered ? 0.18 : 0)))
            .overlay(shape.strokeBorder(Color.white.opacity(isHovered ? 0.55 : 0.16), lineWidth: 0.8))
            .overlay(alignment: .topLeading) {
                if size.width > 70, size.height > 36 {
                    HStack(alignment: .top, spacing: 7) {
                        if size.width > 120, size.height > 44 {
                            Image(nsImage: IconCache.icon(forFile: app.appURL.path))
                                .resizable()
                                .frame(width: 22, height: 22)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                                .font(.system(size: size.width > 160 ? 12.5 : 11, weight: .semibold))
                                .lineLimit(1)
                            if size.height > 46 {
                                Text(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .monospacedDigit()
                                    .opacity(0.8)
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            .contentShape(shape)
            .animation(MotionTokens.snappy, value: isHovered)
            .onHover { inside in
                if inside { hovered = app.id } else if hovered == app.id { hovered = nil }
            }
            .onTapGesture { select(app) }
            .help("\(app.name) · \(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))")
    }
}

// MARK: - List

private struct AppFootprintRow: View {
    @ObservedObject var model: SpaceLensModel
    let app: AppFootprint
    let largest: Int64
    let isExpanded: Bool
    let isHovered: Bool
    let toggle: () -> Void
    let uninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Image(nsImage: IconCache.icon(forFile: app.appURL.path))
                        .resizable()
                        .frame(width: 24, height: 24)
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .frame(width: 170, alignment: .leading)
                    stackedBar
                        .frame(height: 7)
                    Text(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 76, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isExpanded ? 0.06 : (isHovered ? 0.05 : 0)))
                .padding(.horizontal, 6)
        )
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.appURL]) }
            Button("Uninstall…", action: uninstall)
        }
    }

    /// Each part as a segment, scaled against the largest app.
    private var stackedBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * CGFloat(Double(app.totalSize) / Double(max(largest, 1)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                HStack(spacing: 1) {
                    ForEach(app.parts) { part in
                        Rectangle()
                            .fill(PartStyle.of(part.kind).color)
                            .frame(width: max(1, (width - CGFloat(app.parts.count - 1)) * CGFloat(Double(part.size) / Double(max(app.totalSize, 1)))))
                    }
                }
                .frame(width: max(3, width), alignment: .leading)
                .clipShape(Capsule())
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(app.bundleIdentifier)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .textSelection(.enabled)
                Spacer()
                Button("Uninstall…", action: uninstall)
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.small)
            }
            ForEach(app.parts) { part in
                partRow(part)
            }
        }
        .padding(.leading, 58)
        .padding(.trailing, 20)
        .padding(.bottom, 12)
    }

    private func partRow(_ part: AppFootprint.Part) -> some View {
        let style = PartStyle.of(part.kind)
        let share = Double(part.size) / Double(max(app.totalSize, 1))
        let firstPath = part.paths.first
        return HStack(spacing: 10) {
            Circle().fill(style.color).frame(width: 8, height: 8)
            Text(style.title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 120, alignment: .leading)
            GeometryReader { proxy in
                Capsule()
                    .fill(style.color.opacity(0.85))
                    .frame(width: max(2, proxy.size.width * share))
            }
            .frame(height: 4)
            Text(ByteCountFormatter.string(fromByteCount: part.size, countStyle: .file))
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0))))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 44, alignment: .trailing)
            if let firstPath {
                Button {
                    if model.nodes(at: firstPath) != nil {
                        model.showInTreemap(firstPath)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([firstPath])
                    }
                } label: {
                    Image(systemName: model.nodes(at: firstPath) != nil ? "square.grid.3x3.square" : "magnifyingglass")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help(part.paths.count > 1
                      ? Text(String(format: String(localized: "Show the largest of %lld folders"), Int64(part.paths.count)))
                      : Text(firstPath.path))
            }
        }
    }
}
