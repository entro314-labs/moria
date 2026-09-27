import AppKit
import MoriaCore
import Quartz
import SwiftUI

/// The results list: an `NSTableView`, which stays smooth with thousands of rows and gives
/// native column sorting, drag-out to Finder and Quick Look.
struct ResultsTable: NSViewRepresentable {
    let model: SearchModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsTableView()
        table.coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.rowHeight = 46
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.autosaveName = "MoriaResults"
        table.autosaveTableColumns = true

        for column in Coordinator.Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.isHidden = !column.visibleByDefault
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.sort.defaultAscending)
            if column == .size { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        // Right-click the header to choose columns, as in Finder.
        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        table.headerView?.menu = headerMenu
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(model: model)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        enum Column: String, CaseIterable {
            case name, location, kind, ext, size, modified, created

            var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
            var title: String {
                switch self {
                case .name: "Name"
                case .location: "Where"
                case .kind: "Kind"
                case .ext: "Extension"
                case .size: "Size"
                case .modified: "Modified"
                case .created: "Created"
                }
            }
            var width: CGFloat {
                switch self {
                case .name: 520
                case .location: 220
                case .kind: 90
                case .ext: 70
                case .size: 72
                case .modified, .created: 120
                }
            }
            var visibleByDefault: Bool { self != .location && self != .ext && self != .created }
            var minWidth: CGFloat { self == .name ? 220 : 60 }
            var sort: ResultSort {
                switch self {
                case .name: .name
                case .kind: .kind
                case .ext: .ext
                case .size: .size
                case .modified: .modified
                case .location: .path
                case .created: .created
                }
            }
        }

        var model: SearchModel
        weak var table: ResultsTableView?
        private(set) var items: [ResultItem] = []
        private var detailsRevision = -1
        private var focusRequest = 0
        private var quickLookRequest = 0
        private var applyingSelection = false

        init(model: SearchModel) {
            self.model = model
        }

        func update(model: SearchModel) {
            self.model = model
            guard let table else { return }
            if model.items.map(\.id) != items.map(\.id) || model.items != items {
                // Back to the top for a new search, not when results arrive in batches (regex).
                let newSearch = model.items.first?.id != items.first?.id
                items = model.items
                table.reloadData()
                if newSearch, !items.isEmpty { table.scrollRowToVisible(0) }
            } else if model.detailsRevision != detailsRevision {
                let visible = table.rows(in: table.visibleRect)
                if visible.length > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<visible.location + visible.length),
                                     columnIndexes: IndexSet(integer: 0))
                }
            }
            detailsRevision = model.detailsRevision
            syncSelection()
            if model.focusResultsRequest != focusRequest {
                focusRequest = model.focusResultsRequest
                table.window?.makeFirstResponder(table)
            }
            if model.quickLookRequest != quickLookRequest {
                quickLookRequest = model.quickLookRequest
                table.window?.makeFirstResponder(table)
                table.togglePreview()
            }
            // The header shows the sort chosen anywhere (column click or View › Sort By).
            let wanted = Column.allCases.first { $0.sort == model.sort }
                .map { [NSSortDescriptor(key: $0.rawValue, ascending: model.sortAscending)] } ?? []
            if table.sortDescriptors != wanted { table.sortDescriptors = wanted }
        }

        private func syncSelection() {
            guard let table else { return }
            let wanted = IndexSet(items.indices.filter { model.selection.contains(items[$0].id) })
            guard wanted != table.selectedRowIndexes else { return }
            applyingSelection = true
            table.selectRowIndexes(wanted, byExtendingSelection: false)
            applyingSelection = false
            if let first = wanted.first { table.scrollRowToVisible(first) }
        }

        var selectedURLs: [URL] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].result.url : nil }
        }

        private var clickedOrSelectedURLs: [URL] {
            guard let table else { return [] }
            let row = table.clickedRow
            if row >= 0, !table.selectedRowIndexes.contains(row), items.indices.contains(row) {
                return [items[row].result.url]
            }
            return selectedURLs
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard items.indices.contains(row) else { return nil }
            return items[row].result.url as NSURL
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let column = Column(rawValue: descriptor.key ?? "") else { return }
            model.sort = column.sort
            model.sortAscending = descriptor.ascending
        }

        // MARK: Delegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                  items.indices.contains(row) else { return nil }
            let item = items[row]
            switch column {
            case .name:
                let cell = tableView.makeView(withIdentifier: ResultCell.identifier, owner: nil) as? ResultCell ?? ResultCell()
                let details = model.details[item.id]
                cell.configure(item: item, details: details)
                if details == nil { model.requestDetails(for: item) }
                return cell
            case .kind:
                return textCell(tableView, item.result.isDirectory && item.result.kind == .folder ? "Folder" : item.result.kind.displayName)
            case .size:
                return textCell(tableView, Display.size(item.result), alignment: .right)
            case .modified:
                let cell = textCell(tableView, Display.date(item.result.modified))
                cell.toolTip = Display.absoluteDate.string(from: item.result.modified)
                return cell
            case .created:
                let cell = textCell(tableView, Display.date(item.result.created))
                cell.toolTip = Display.absoluteDate.string(from: item.result.created)
                return cell
            case .location:
                let cell = textCell(tableView, Display.parent(of: item.result.path))
                cell.textField?.lineBreakMode = .byTruncatingHead
                cell.toolTip = item.result.path
                return cell
            case .ext:
                return textCell(tableView, item.result.ext.isEmpty ? "—" : item.result.ext)
            }
        }

        private func textCell(_ tableView: NSTableView, _ text: String, alignment: NSTextAlignment = .left) -> NSTableCellView {
            let identifier = NSUserInterfaceItemIdentifier("text")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.textColor = .secondaryLabelColor
                field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            cell.textField?.stringValue = text
            cell.textField?.alignment = alignment
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.toolTip = nil
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            model.selection = Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil })
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
        }

        // MARK: Actions

        @objc func openClicked() {
            guard let table, table.clickedRow >= 0 else { return }
            // The double-click selected the row; opening through the model records the search.
            model.openSelection()
        }

        func openSelection() { model.openSelection() }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === table?.headerView?.menu {
                for column in table?.tableColumns ?? [] where column.identifier.rawValue != Column.name.rawValue {
                    let item = NSMenuItem(title: column.title, action: #selector(MenuAction.run), keyEquivalent: "")
                    let handler = MenuAction { column.isHidden.toggle() }
                    item.target = handler
                    item.representedObject = handler
                    item.state = column.isHidden ? .off : .on
                    menu.addItem(item)
                }
                return
            }
            let urls = clickedOrSelectedURLs
            guard !urls.isEmpty else { return }
            func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
                let handler = MenuAction(action)
                item.target = handler
                item.representedObject = handler
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
            add("Open", "arrow.up.forward.app") { FileActions.open(urls) }
            add("Show in Finder", "folder") { FileActions.reveal(urls) }
            let clickedRow = table?.clickedRow ?? -1
            add("Quick Look", "eye") { [weak self] in
                // Quick Look shows the selection, so select the row that was right-clicked.
                guard let table = self?.table else { return }
                if clickedRow >= 0, !table.selectedRowIndexes.contains(clickedRow) {
                    table.selectRowIndexes([clickedRow], byExtendingSelection: false)
                }
                table.togglePreview()
            }
            menu.addItem(.separator())
            add("Copy Path", "doc.on.clipboard") { FileActions.copyPaths(urls) }
            add("Copy File", "doc.on.doc") { FileActions.copyFiles(urls) }
            if urls.count == 1 {
                menu.addItem(.separator())
                add("Open in Terminal", "terminal") { FileActions.openTerminal(at: urls[0]) }
            }
        }
    }
}

/// Target for closure-based menu items (kept alive via `representedObject`).
final class MenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

// MARK: - Table view with keyboard shortcuts and Quick Look

final class ResultsTableView: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var coordinator: ResultsTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  // Return, Enter
            if event.modifierFlags.contains(.command) {
                FileActions.reveal(coordinator?.selectedURLs ?? [])
            } else {
                coordinator?.openSelection()
            }
        case 49:  // Space
            if !selectedRowIndexes.isEmpty { togglePreview() }
        default:
            super.keyDown(with: event)
        }
    }

    /// ⌘C copies the selected files, as in Finder.
    @objc func copy(_ sender: Any?) {
        FileActions.copyFiles(coordinator?.selectedURLs ?? [])
    }

    func togglePreview() {
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    // Quick Look calls these on the main thread; AppKit declares them nonisolated.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { coordinator?.selectedURLs.count ?? 0 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { coordinator?.selectedURLs[index] as NSURL? }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys in the panel move the table selection.
        guard let event, event.type == .keyDown, [125, 126].contains(event.keyCode) else { return false }
        nonisolated(unsafe) let arrow = event  // delivered on the main thread
        MainActor.assumeIsolated { keyDown(with: arrow) }
        return true
    }
}

// MARK: - Name cell

/// Two-line cell: icon, name and "why it matched" labels; below, the excerpt or the folder.
final class ResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("result")

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let labels = NSStackView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        labels.orientation = .horizontal
        labels.spacing = 4
        for view in [icon, name, detail, labels] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.required, for: .horizontal)
        labels.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            labels.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(item: ResultItem, details: MatchDetails?) {
        let result = item.result
        icon.image = IconCache.icon(for: result)
        icon.alphaValue = result.isCloudOnly ? 0.55 : 1
        name.stringValue = result.name
        toolTip = result.path

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        if let line = item.lines.first {
            detail.lineBreakMode = .byTruncatingTail
            detail.attributedStringValue = NSAttributedString(
                string: "\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                             .foregroundColor: NSColor.secondaryLabelColor]
            )
        } else if let snippet = details?.snippet {
            detail.lineBreakMode = .byTruncatingTail
            detail.attributedStringValue = Display.highlighted(snippet, font: font, color: .secondaryLabelColor)
        } else {
            // Middle truncation keeps both the top-level location and the enclosing folder.
            detail.lineBreakMode = .byTruncatingMiddle
            detail.attributedStringValue = NSAttributedString(
                string: Display.parent(of: result.path),
                attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            )
        }

        labels.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for label in MatchLabel.labels(for: item, details: details) {
            labels.addArrangedSubview(Self.capsule(label))
        }
    }

    /// White text on the blue selection highlight, as in Finder.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            for case let capsule in labels.arrangedSubviews {
                guard let field = capsule.subviews.first as? NSTextField, let label = capsule.identifier.map(\.rawValue) else { continue }
                let color = emphasized ? NSColor.white : MatchLabel.color(named: label)
                field.textColor = color
                capsule.layer?.backgroundColor = color.withAlphaComponent(emphasized ? 0.22 : 0.14).cgColor
            }
        }
    }

    private static func capsule(_ label: MatchLabel) -> NSView {
        let field = NSTextField(labelWithString: label.text)
        field.font = .systemFont(ofSize: 10, weight: .semibold)
        field.textColor = label.color
        field.toolTip = label.help
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier(label.colorName)
        container.wantsLayer = true
        container.layer?.backgroundColor = label.color.withAlphaComponent(0.14).cgColor
        container.layer?.cornerRadius = 7
        container.layer?.cornerCurve = .continuous
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
        ])
        container.setAccessibilityElement(true)
        container.setAccessibilityLabel(label.help)
        return container
    }
}

/// "Why this matched" labels shown on each result.
struct MatchLabel: Hashable {
    var text: String
    var help: String
    var colorName: String

    var color: NSColor { Self.color(named: colorName) }

    static func color(named name: String) -> NSColor {
        switch name {
        case "blue": .systemBlue
        case "purple": .systemPurple
        default: .secondaryLabelColor
        }
    }

    static func labels(for item: ResultItem, details: MatchDetails?) -> [MatchLabel] {
        let result = item.result
        var labels: [MatchLabel] = []
        if result.matchedName {
            labels.append(MatchLabel(text: "Name", help: "The name matches", colorName: "gray"))
        }
        if !item.lines.isEmpty {
            let count = item.lines.count
            labels.append(MatchLabel(text: count == 1 ? "Line \(item.lines[0].number)" : "\(count) lines",
                                     help: "Matching lines in the file", colorName: "blue"))
        } else if result.matchedContent {
            let base = result.kind == .image ? "Text in image" : "Contents"
            let count = details?.matchCount ?? 0
            labels.append(MatchLabel(text: count > 1 ? "\(base) · \(count)" : base,
                                     help: count > 1 ? "\(count) matching lines" : "The text inside matches",
                                     colorName: "blue"))
        }
        if result.matchedMeaning {
            labels.append(MatchLabel(text: "Meaning", help: "Related in meaning to your words", colorName: "purple"))
        }
        if result.isCloudOnly {
            labels.append(MatchLabel(text: "Cloud", help: "Not downloaded; indexed by name only", colorName: "gray"))
        }
        return labels
    }
}
