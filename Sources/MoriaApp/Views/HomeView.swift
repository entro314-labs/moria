import MoriaCore
import QuickLookThumbnailing
import SwiftUI

/// Shown when nothing is being searched: recently changed files, collections and recent
/// searches, so the window is useful before typing.
struct HomeView: View {
    let model: SearchModel

    private var recentSearches: [String] {
        UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !model.recentFiles.isEmpty {
                    section("Recently Changed") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)], spacing: 14) {
                            ForEach(model.recentFiles.prefix(12)) { file in
                                RecentFileCard(file: file)
                            }
                        }
                    }
                }
                section("Collections") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 10)], spacing: 10) {
                        ForEach(Collection.all) { collection in
                            CollectionCard(collection: collection, count: model.counts[.collection(collection.name)]) {
                                model.sidebarSelection = .collection(collection.name)
                            }
                        }
                    }
                }
                if !recentSearches.isEmpty {
                    section("Recent Searches") {
                        FlowLayout(spacing: 6) {
                            ForEach(recentSearches, id: \.self) { query in
                                Button(query) { model.text = query }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                }
                KeyboardHints()
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
    }
}

private struct RecentFileCard: View {
    let file: SearchResult
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        Button {
            FileActions.open([file.url])
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5))
                    Image(nsImage: thumbnail ?? IconCache.icon(for: file))
                        .resizable()
                        .aspectRatio(contentMode: thumbnail == nil ? .fit : .fill)
                        .padding(thumbnail == nil ? 24 : 0)
                }
                .frame(height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(file.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text("\(Display.date(file.modified)) · \((file.path as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Display.abbreviate(file.path))
        .contextMenu {
            Button("Open") { FileActions.open([file.url]) }
            Button("Show in Finder") { FileActions.reveal([file.url]) }
            Button("Copy Path") { FileActions.copyPaths([file.url]) }
        }
        .draggable(file.url)
        .task(id: file.id) {
            guard !file.isCloudOnly else { return }
            let request = QLThumbnailGenerator.Request(fileAt: file.url, size: CGSize(width: 190, height: 104),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                       representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

private struct CollectionCard: View {
    let collection: Collection
    let count: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: collection.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.name).fontWeight(.medium)
                    Text(count.map { $0 >= 1000 ? "1,000+ items" : "\($0.formatted()) items" } ?? "Counting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.quaternary.opacity(hovering ? 0.8 : 0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(collection.query)
    }
}

private struct KeyboardHints: View {
    private let hints: [(String, String)] = [
        ("⌥⌘F", "Search"), ("⌘1–⌘5", "Mode"), ("↩", "Open"), ("Space", "Quick Look"),
        ("⌘R", "Show in Finder"), ("⌘K", "Actions"), ("⌘S", "Save search"), ("⌃⌥Space", "Quick search anywhere"),
    ]

    var body: some View {
        FlowLayout(spacing: 14) {
            ForEach(hints, id: \.0) { key, label in
                HStack(spacing: 5) {
                    Text(key)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Wrapping horizontal layout for chips and hints.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
