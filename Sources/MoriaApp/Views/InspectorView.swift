import ImageIO
import MoriaCore
import PDFKit
import Quartz
import SwiftUI

/// What the inspector shows: the preview, the details, or both stacked in a resizable split.
enum InspectorLayout: String, CaseIterable, Identifiable {
    case preview, both, info

    var id: String { rawValue }
    var title: String {
        switch self {
        case .preview: "Preview"
        case .both: "Preview and Info"
        case .info: "Info"
        }
    }
    var symbol: String {
        switch self {
        case .preview: "eye"
        case .both: "rectangle.split.1x2"
        case .info: "info.circle"
        }
    }
}

/// Preview and details for the selected result.
struct InspectorView: View {
    let model: SearchModel
    @AppStorage("inspectorLayout") private var layout: InspectorLayout = .both

    var body: some View {
        Group {
            if let item = model.selectedItems.first {
                switch layout {
                case .preview:
                    PreviewPane(result: item.result)
                case .info:
                    InfoPane(model: model, item: item)
                case .both:
                    VSplitView {
                        PreviewPane(result: item.result)
                            .frame(minHeight: 160, idealHeight: 380)
                        InfoPane(model: model, item: item)
                            .frame(minHeight: 180)
                    }
                }
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "sidebar.trailing",
                                       description: Text("Select a result to preview it and see why it matched."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Show", selection: $layout) {
                    ForEach(InspectorLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Show the preview, the info, or both")
            }
        }
    }
}

// MARK: - Preview

private struct PreviewPane: View {
    let result: SearchResult

    var body: some View {
        Group {
            if result.isOffline {
                ContentUnavailableView("Drive Not Connected", systemImage: "externaldrive.badge.xmark",
                                       description: Text("Connect the drive to preview or open this file. Its indexed text is still searchable."))
            } else if result.isCloudOnly {
                // Quick Look runs in another process that would download the file.
                ContentUnavailableView {
                    Label("In the Cloud", systemImage: "icloud")
                } description: {
                    Text("This file isn't downloaded. Opening it downloads it.")
                } actions: {
                    Button("Open") { FileActions.open([result.url]) }
                }
            } else {
                QuickLookPreview(url: result.url)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Info

private struct InfoPane: View {
    let model: SearchModel
    let item: ResultItem
    @State private var currentMatch = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var facts: [(String, String)] = []

    private var result: SearchResult { item.result }
    private static let shownLines = 100

    /// Matching lines: from a regex search, or loaded match details.
    private var lines: [(number: Int, text: String)] {
        if !item.lines.isEmpty { return item.lines.map { ($0.number, $0.text) } }
        return model.details[item.id]?.lines.map { ($0.number, $0.text) } ?? []
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    actions
                    matches(proxy)
                    details
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: item.id) { currentMatch = 0 }
        .task(id: item.id) { facts = await Self.facts(for: result) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: IconCache.icon(for: result))
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.name)
                    .font(.headline)
                    .textSelection(.enabled)
                    .lineLimit(3)
                PathBreadcrumb(path: (result.path as NSString).deletingLastPathComponent) { folder in
                    model.filters.folder = folder
                }
                HStack(spacing: 4) {
                    ForEach(MatchLabel.labels(for: item, details: model.details[item.id]), id: \.self) { label in
                        Text(label.text)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(nsColor: label.color))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .chipBackground(Color(nsColor: label.color))
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Open", systemImage: "arrow.up.forward.app") { FileActions.open([result.url]) }
            Button("Show in Finder", systemImage: "folder") { FileActions.reveal([result.url]) }
                .labelStyle(.iconOnly)
                .help("Show in Finder (⌘R)")
            ShareLink(item: result.url) { Label("Share", systemImage: "square.and.arrow.up") }
                .labelStyle(.iconOnly)
                .help("Share")
            Menu {
                Button("Copy Path") { FileActions.copyPaths([result.url]) }
                Button("Copy File") { FileActions.copyFiles([result.url]) }
                Button("Search in This Folder") { model.filters.folder = (result.path as NSString).deletingLastPathComponent }
                if model.canUseMeaning {
                    Button("Find Similar") { model.findSimilar(to: result.path) }
                }
                Button("Open in Terminal") { FileActions.openTerminal(at: result.url) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("More actions")
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
    }

    @ViewBuilder
    private func matches(_ proxy: ScrollViewProxy) -> some View {
        let lines = lines
        if !lines.isEmpty {
            let total = item.lines.isEmpty ? (model.details[item.id]?.matchCount ?? lines.count) : lines.count
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionTitle(total == 1 ? "1 Match" : "\(total.formatted()) Matches")
                    Spacer()
                    // Only the lines drawn below (the first 100) can be stepped to.
                    let shown = min(lines.count, Self.shownLines)
                    ControlGroup {
                        Button("Previous Match", systemImage: "chevron.up") { step(-1, shown, proxy) }
                            .help("Previous match (⇧⌘G)")
                        Button("Next Match", systemImage: "chevron.down") { step(1, shown, proxy) }
                            .help("Next match (⌘G)")
                    }
                    .controlSize(.small)
                    .fixedSize()
                    // Edit › Next Match / Previous Match (⌘G / ⇧⌘G), as in HoudahSpot and Find.
                    .onChange(of: model.matchStep) { _, request in step(request.delta, shown, proxy) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.prefix(Self.shownLines).enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(line.number)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 30, alignment: .trailing)
                            Text(AttributedString(Display.highlighted(line.text, font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                                                      color: .labelColor)))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                        .background(index == currentMatch ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .id(index)
                        .onTapGesture { currentMatch = index }
                    }
                    if total > Self.shownLines {
                        Text("and \((total - Self.shownLines).formatted()) more").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
            }
        } else if let passage = model.details[item.id]?.passage {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Closest Passage")
                Text(passage)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func step(_ delta: Int, _ count: Int, _ proxy: ScrollViewProxy) {
        guard count > 0 else { return }
        currentMatch = (currentMatch + delta + count) % count
        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(currentMatch, anchor: .center) }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Information")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Kind", result.isDirectory && result.kind == .folder ? "Folder" : result.kind.displayName)
                if !result.isDirectory { row("Size", ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file)) }
                ForEach(facts, id: \.0) { row($0.0, $0.1) }
                if !result.tags.isEmpty { row("Tags", result.tags.joined(separator: ", ")) }
                if let taken = result.taken { row("Taken", Display.absoluteDate.string(from: taken)) }
                if let duration = result.duration { row("Duration", Display.duration(duration)) }
                if let author = result.author { row("Author", author) }
                row("Modified", Display.absoluteDate.string(from: result.modified))
                row("Created", Display.absoluteDate.string(from: result.created))
                if result.isCloudOnly { row("Storage", "In the cloud, not downloaded") }
                if result.isOffline { row("Storage", "On a drive that isn't connected") }
                row("Path", Display.abbreviate(result.path))
            }
            .font(.callout)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(4)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// Cheap format-specific facts: image dimensions, PDF page count. Read off the main thread:
    /// a large PDF or a slow volume would otherwise stall the window.
    @concurrent
    private nonisolated static func facts(for result: SearchResult) async -> [(String, String)] {
        guard !result.isCloudOnly, !result.isOffline, !result.isDirectory else { return [] }
        switch result.kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(result.url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return [] }
            return [("Dimensions", "\(width) × \(height)")]
        case .pdf:
            guard let document = CGPDFDocument(result.url as CFURL) else { return [] }
            return [("Pages", document.numberOfPages.formatted())]
        default:
            return []
        }
    }
}

/// The folder path as clickable components; clicking one searches inside it.
private struct PathBreadcrumb: View {
    let path: String
    let select: (String) -> Void

    private var components: [(name: String, path: String)] {
        let home = NSHomeDirectory()
        var result: [(String, String)] = []
        var current = path
        while current.count > 1 {
            let name = current == home ? "~" : (current as NSString).lastPathComponent
            result.insert((name, current), at: 0)
            if current == home { break }
            current = (current as NSString).deletingLastPathComponent
        }
        // The last folders are the informative ones; the full path is in Information.
        return result.count > 4 ? [("…", result[result.count - 5].1)] + result.suffix(4) : result
    }

    var body: some View {
        FlowLayout(spacing: 2) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                HStack(spacing: 2) {
                    if index > 0 {
                        Image(systemName: "chevron.compact.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button(component.name) { select(component.path) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Search in \(Display.abbreviate(component.path))")
                }
            }
        }
    }
}

/// Embedded Quick Look preview.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
