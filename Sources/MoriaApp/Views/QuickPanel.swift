import AppKit
import MoriaCore
import SwiftUI

/// The floating quick-search panel shown by the global shortcut.
///
/// A non-activating panel, like Spotlight: it takes keyboard focus without bringing Moria's
/// other windows forward, and closes when it loses focus.
@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    private let panel: QuickPanelWindow
    private let model: SearchModel

    init(app: AppModel, openInMain: @escaping @MainActor (String) -> Void) {
        model = SearchModel(app: app, limit: 30)
        panel = QuickPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: true
        )
        super.init()
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.delegate = self
        // Esc clears the text first, then closes (as Spotlight does).
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if model.text.isEmpty { close() } else { model.text = "" }
        }
        let root = QuickPanelView(model: model, close: { [weak self] in self?.close() }, openInMain: { [weak self] text in
            self?.close()
            openInMain(text)
        })
        .environment(app)
        panel.contentView = NSHostingView(rootView: root)
    }

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - frame.height * 0.12))
        }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .moriaQuickPanelShown, object: nil)
    }

    func close() {
        panel.orderOut(nil)
    }


    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

final class QuickPanelWindow: NSPanel {
    /// Esc from anywhere in the panel (including the text field) lands here.
    var onEscape: () -> Void = {}

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }
}

extension Notification.Name {
    static let moriaQuickPanelShown = Notification.Name("MoriaQuickPanelShown")
}

struct QuickPanelView: View {
    @Bindable var model: SearchModel
    let close: () -> Void
    let openInMain: (String) -> Void
    @FocusState private var focused: Bool

    private var selectedIndex: Int? {
        model.items.firstIndex { model.selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Search names and contents", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24))
                    .focused($focused)
                    .onSubmit { openSelected() }
                if model.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(16)
            if !model.activeChips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.activeChips) { chip in
                        Label(chip.label, systemImage: chip.symbol)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.tint.opacity(0.14), in: Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            if !model.items.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.items) { item in
                                QuickRow(item: item, snippet: model.details[item.id]?.snippet, selected: model.selection.contains(item.id))
                                    .id(item.id)
                                    .onTapGesture(count: 2) { FileActions.open([item.result.url]); close() }
                                    .onTapGesture { model.selection = [item.id] }
                                    .onAppear { model.requestDetails(for: item) }
                            }
                        }
                        .padding(6)
                        if model.items.count == model.limit {
                            Button("Show all results in Moria  ⌘O") { openInMain(model.text) }
                                .buttonStyle(.link)
                                .padding(.bottom, 8)
                        }
                    }
                    .onChange(of: model.selection) { _, selection in
                        if let id = selection.first { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↩", "Open")
                hint("⌘R", "Show in Finder")
                hint("⌘O", "Open in Moria")
                Spacer()
                Text(model.summary).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 720)
        .frame(maxHeight: 460, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(keys: ["o", "r"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if press.characters == "o" {
                openInMain(model.text)
            } else if let item = model.selectedItems.first {
                FileActions.reveal([item.result.url])
                close()
            }
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .moriaQuickPanelShown)) { _ in
            focused = true
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.medium)
            Text(label)
        }
    }

    private func move(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        let next = max(0, min(model.items.count - 1, (selectedIndex ?? -1) + delta))
        model.selection = [model.items[next].id]
    }

    /// Return opens; ⌘Return shows in Finder.
    private func openSelected() {
        guard let item = model.selectedItems.first else { return }
        if NSEvent.modifierFlags.contains(.command) {
            FileActions.reveal([item.result.url])
        } else {
            FileActions.open([item.result.url])
        }
        close()
    }
}

private struct QuickRow: View {
    let item: ResultItem
    let snippet: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(for: item.result))
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(item.result.isCloudOnly ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.result.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Group {
                    if let snippet {
                        Text(AttributedString(Display.highlighted(snippet, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)))
                    } else {
                        Text(Display.parent(of: item.result.path)).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Display.date(item.result.modified))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
