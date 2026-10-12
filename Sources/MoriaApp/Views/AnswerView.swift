import MoriaCore
import SwiftUI

/// Answer mode: the question, the answer as it is written, and the sources it cites. Each
/// citation and source selects its row below, so the file is previewed with its matches.
struct AnswerView: View {
    let model: SearchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let answer = model.answer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "questionmark.bubble").foregroundStyle(.tint)
                    Text(answer.question).font(.headline)
                    Spacer()
                    if answer.isWorking {
                        ProgressView().controlSize(.small)
                        Button("Stop", action: model.stop).buttonStyle(.borderless).font(.caption)
                    }
                }
                if let problem = answer.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if answer.text.isEmpty {
                    Text(answer.sources.isEmpty ? "Looking for files that bear on this…" : "Reading \(answer.sources.count) files…")
                        .foregroundStyle(.secondary)
                } else {
                    // No fixedSize here: inside the results column's inset it made the window's
                    // content outgrow the window.
                    Text(Self.attributed(answer.text))
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if url.scheme == "moria-source", let number = Int(url.host() ?? "") { model.selectSource(number) }
                            return .handled
                        })
                }
                if !answer.sources.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(answer.sources.enumerated()), id: \.element.id) { index, source in
                            Button {
                                model.selectSource(index + 1)
                            } label: {
                                HStack(spacing: 5) {
                                    Text("\(index + 1)").font(.caption2.weight(.bold)).monospacedDigit()
                                    Image(nsImage: IconCache.icon(for: source.result)).resizable().frame(width: 16, height: 16)
                                    Text(source.result.name).lineLimit(1).truncationMode(.middle)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .chipBackground(model.selection.contains(source.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .help(Display.abbreviate(source.result.path))
                            .accessibilityLabel("Source \(index + 1), \(source.result.name)")
                        }
                    }
                }
                Text("From the text of these files only, written on this Mac. Check the sources before relying on it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .default, value: answer.sources.count)
            .animation(reduceMotion ? nil : .default, value: answer.isWorking)
        }
    }

    /// The answer with each `[n]` as a link that selects source n.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        var rest = text[...]
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]"),
              let number = Int(rest[rest.index(after: open)..<close]) {
            result += AttributedString(rest[..<open])
            var citation = AttributedString("[\(number)]")
            citation.link = URL(string: "moria-source://\(number)")
            citation.foregroundColor = .accentColor
            citation.font = .body.weight(.semibold)
            result += citation
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(rest)
        return result
    }
}
