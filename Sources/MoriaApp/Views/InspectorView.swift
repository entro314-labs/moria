import MoriaCore
import Quartz
import SwiftUI

/// Preview and details for the selected result.
struct InspectorView: View {
    let model: SearchModel

    var body: some View {
        if let item = model.selectedItems.first {
            VStack(spacing: 0) {
                preview(item.result)
                    .frame(minHeight: 220, maxHeight: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(item.result)
                        actions(item.result)
                        matches(item)
                        details(item.result)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
            }
            .id(item.id)
        } else {
            ContentUnavailableView("No Selection", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select a result to preview it."))
        }
    }

    @ViewBuilder
    private func preview(_ result: SearchResult) -> some View {
        if result.isCloudOnly {
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
        }
    }

    private func header(_ result: SearchResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: IconCache.icon(for: result))
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(.headline)
                    .textSelection(.enabled)
                    .lineLimit(3)
                Text(Display.parent(of: result.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private func actions(_ result: SearchResult) -> some View {
        HStack(spacing: 8) {
            Button("Open", systemImage: "arrow.up.forward.app") { FileActions.open([result.url]) }
            Button("Show in Finder", systemImage: "folder") { FileActions.reveal([result.url]) }
            Button("Copy Path", systemImage: "doc.on.clipboard") { FileActions.copyPaths([result.url]) }
                .labelStyle(.iconOnly)
                .help("Copy Path")
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func matches(_ item: ResultItem) -> some View {
        if !item.lines.isEmpty {
            section("Matching Lines") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.lines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(line.number)")
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 28, alignment: .trailing)
                            Text(line.text.trimmingCharacters(in: .whitespaces))
                                .textSelection(.enabled)
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        } else if let snippet = model.snippets[item.id] {
            section(item.result.matchedMeaning && !item.result.matchedContent ? "Related Passage" : "Match") {
                Text(AttributedString(Display.highlighted(snippet, font: .systemFont(ofSize: 12), color: .labelColor)))
                    .textSelection(.enabled)
            }
        }
    }

    private func details(_ result: SearchResult) -> some View {
        section("Information") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("Kind", result.kind.displayName)
                if !result.isDirectory { row("Size", ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file)) }
                row("Modified", Display.absoluteDate.string(from: result.modified))
                row("Created", Display.absoluteDate.string(from: result.created))
                row("Matched", [result.matchedName ? "name" : nil, result.matchedContent ? "contents" : nil,
                                result.matchedMeaning ? "meaning" : nil].compactMap { $0 }.joined(separator: ", "))
                if result.isCloudOnly { row("Storage", "Cloud only") }
            }
            .font(.caption)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
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
