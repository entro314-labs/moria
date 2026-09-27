import Foundation
import FoundationModels

/// Turns a plain-language request ("pdf invoices about rent from last spring") into a
/// `SearchQuery` using the on-device Apple Foundation Model.
///
/// The model only fills a constrained schema; all date arithmetic is done in Swift from the
/// model's period choice, because the model is unreliable at calendar math. Callers should
/// fall back to `QueryParser` if this throws.
public struct NaturalLanguageQuery: Sendable {
    public var now: Date
    public var calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    public struct Interpretation: Sendable {
        public var query: SearchQuery
        /// Human-readable description of the filters, shown under the search field.
        public var summary: String
    }

    public enum NLQueryError: Error, CustomStringConvertible {
        case modelUnavailable(String)

        public var description: String {
            switch self {
            case let .modelUnavailable(reason): "The on-device language model is unavailable: \(reason)"
            }
        }
    }

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Loads the model ahead of the first query (the first call otherwise takes seconds).
    public static func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(instructions: instructions).prewarm()
    }

    public func interpret(_ request: String) async throws -> Interpretation {
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            throw NLQueryError.modelUnavailable(String(describing: availability))
        }
        let session = LanguageModelSession(instructions: Self.instructions)
        let prompt = "Today is \(Self.dayFormatter.string(from: now)). Request: \(request)"
        let response = try await session.respond(to: prompt, generating: ParsedRequest.self)
        return interpretation(of: response.content)
    }

    static let instructions = """
        You convert a person's request to find files on their Mac into search filters. \
        keywords are only the distinctive words to look for inside files or names: drop filler words, \
        drop words that only describe the file type or the date. Use fileKinds for broad types and \
        extensions only when a specific format is named. Choose datePeriod only if the request mentions time. \
        Seasons: spring is March to May, summer June to August, autumn September to November, winter December to February.
        """

    func interpretation(of parsed: ParsedRequest) -> Interpretation {
        var query = SearchQuery()
        query.terms = parsed.keywords.flatMap { $0.split(separator: " ").map(String.init) }.filter { !$0.isEmpty }
        query.kinds = Set(parsed.fileKinds.map(\.fileKind))
        query.extensions = Set(parsed.extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty })
        if let interval = dateInterval(parsed.datePeriod, year: parsed.year, month: parsed.month) {
            if parsed.dateField == .created { query.created = interval } else { query.modified = interval }
        }
        if let min = parsed.minimumSizeMegabytes, min > 0 { query.minSize = Int64(min * 1_048_576) }
        if let max = parsed.maximumSizeMegabytes, max > 0 { query.maxSize = Int64(max * 1_048_576) }
        return Interpretation(query: query, summary: summary(of: query))
    }

    /// Resolves the model's period choice to concrete dates.
    func dateInterval(_ period: ParsedRequest.Period, year: Int?, month: Int?) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        let thisYear = calendar.component(.year, from: now)
        let end = now.addingTimeInterval(1)
        func back(_ unit: Calendar.Component, _ value: Int) -> DateInterval {
            DateInterval(start: calendar.date(byAdding: unit, value: -value, to: today)!, end: end)
        }
        func span(fromMonth: Int, months: Int, year: Int) -> DateInterval? {
            guard let start = calendar.date(from: DateComponents(year: year, month: fromMonth, day: 1)),
                  let stop = calendar.date(byAdding: .month, value: months, to: start) else { return nil }
            return DateInterval(start: start, end: stop)
        }
        /// The most recent occurrence of a season that has started.
        func season(startMonth: Int) -> DateInterval? {
            var seasonYear = year ?? thisYear
            if year == nil, let candidate = span(fromMonth: startMonth, months: 3, year: seasonYear), candidate.start > now {
                seasonYear -= 1
            }
            return span(fromMonth: startMonth, months: 3, year: seasonYear)
        }
        switch period {
        case .none: return nil
        case .today: return DateInterval(start: today, end: end)
        case .yesterday: return DateInterval(start: calendar.date(byAdding: .day, value: -1, to: today)!, end: today)
        case .pastWeek: return back(.day, 7)
        case .pastMonth: return back(.month, 1)
        case .pastThreeMonths: return back(.month, 3)
        case .pastYear: return back(.year, 1)
        case .thisYear: return span(fromMonth: 1, months: 12, year: thisYear)
        case .lastYear: return span(fromMonth: 1, months: 12, year: thisYear - 1)
        case .specificYear:
            guard let year else { return nil }
            return span(fromMonth: 1, months: 12, year: year)
        case .specificMonth:
            guard let month, (1...12).contains(month) else { return nil }
            var monthYear = year ?? thisYear
            if year == nil, let candidate = span(fromMonth: month, months: 1, year: monthYear), candidate.start > now {
                monthYear -= 1
            }
            return span(fromMonth: month, months: 1, year: monthYear)
        case .spring: return season(startMonth: 3)
        case .summer: return season(startMonth: 6)
        case .autumn: return season(startMonth: 9)
        case .winter: return season(startMonth: 12)
        }
    }

    func summary(of query: SearchQuery) -> String {
        var parts: [String] = []
        if !query.terms.isEmpty { parts.append("“" + query.terms.joined(separator: " ") + "”") }
        if !query.kinds.isEmpty { parts.append(query.kinds.map(\.displayName).sorted().joined(separator: ", ")) }
        if !query.extensions.isEmpty { parts.append(query.extensions.sorted().map { "." + $0 }.joined(separator: ", ")) }
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        if let modified = query.modified { parts.append("modified " + formatter.string(from: modified)!) }
        if let created = query.created { parts.append("created " + formatter.string(from: created)!) }
        if let min = query.minSize { parts.append("≥ " + ByteCountFormatter.string(fromByteCount: min, countStyle: .file)) }
        if let max = query.maxSize { parts.append("≤ " + ByteCountFormatter.string(fromByteCount: max, countStyle: .file)) }
        return parts.isEmpty ? "all files" : parts.joined(separator: " · ")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// The schema the model fills.
@Generable
struct ParsedRequest: Equatable {
    @Generable
    enum Kind: Equatable {
        case document, pdf, image, audio, video, archive, text, code, folder, application

        var fileKind: FileKind {
            switch self {
            case .document: .document
            case .pdf: .pdf
            case .image: .image
            case .audio: .audio
            case .video: .video
            case .archive: .archive
            case .text: .text
            case .code: .code
            case .folder: .folder
            case .application: .application
            }
        }
    }

    @Generable
    enum Period: Equatable {
        case none, today, yesterday, pastWeek, pastMonth, pastThreeMonths, pastYear, thisYear, lastYear
        case specificYear, specificMonth, spring, summer, autumn, winter
    }

    @Generable
    enum DateField: Equatable {
        case modified, created
    }

    @Guide(description: "Distinctive words to search for in file names or contents; empty if none")
    var keywords: [String]
    @Guide(description: "Broad file types requested; empty for any")
    var fileKinds: [Kind]
    @Guide(description: "Specific file extensions named in the request, without the dot; empty for any")
    var extensions: [String]
    @Guide(description: "The time period mentioned, or none")
    var datePeriod: Period
    @Guide(description: "Whether the time refers to when files were modified (default) or created")
    var dateField: DateField
    @Guide(description: "Year for specificYear, specificMonth or a season, if stated")
    var year: Int?
    @Guide(description: "Month number 1-12 for specificMonth")
    var month: Int?
    @Guide(description: "Minimum size in megabytes, if requested")
    var minimumSizeMegabytes: Double?
    @Guide(description: "Maximum size in megabytes, if requested")
    var maximumSizeMegabytes: Double?
}
