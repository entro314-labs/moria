import SwiftUI

/// First-launch sheet: what Moria does, and the Full Disk Access it needs to be thorough.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Moria").font(.largeTitle.weight(.semibold))
                    Text("Deep search for everything on your Mac.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                point("magnifyingglass", "Every file, by name", "Including hidden files, app data and cloud folders, with folder, date, size and type filters.")
                point("doc.text", "Text inside files", "Documents, PDFs, code, and text in screenshots and scans. Cloud-only files are never downloaded.")
                point("bolt", "Always current", "Changes are picked up as they happen."
                    + (app.hotKeyChoice == .none ? "" : " Press \(app.hotKeyChoice.label) anywhere for quick search."))
            }
            GroupBox {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: app.hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield")
                        .font(.title)
                        .foregroundStyle(app.hasFullDiskAccess ? .green : .orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.hasFullDiskAccess ? "Full Disk Access is on" : "Allow Full Disk Access").font(.headline)
                        Text("macOS hides Mail, Messages, Safari and other app data from every app unless you allow it. Moria reads files only to index them on this Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if !app.hasFullDiskAccess {
                            Button("Open Privacy Settings…") { FullDiskAccess.openSystemSettings() }
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(6)
            }
            HStack {
                Text("Indexing has started and continues in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start Searching", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshAccess()
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
