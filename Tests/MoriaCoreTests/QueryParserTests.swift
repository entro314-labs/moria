import Foundation
import Testing
@testable import MoriaCore

struct QueryParserTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Athens")!
        return calendar
    }()
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 12))! }
    var parser: QueryParser { QueryParser(now: now, calendar: calendar, home: "/Users/test") }

    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func termsPhrasesAndExclusions() {
        let query = parser.parse(#"invoice "rent receipt" -draft 10:30"#)
        #expect(query.terms == ["invoice", "10:30"])
        #expect(query.phrases == ["rent receipt"])
        #expect(query.excludedTerms == ["draft"])
    }

    @Test func extensionKindAndFolderFilters() {
        let query = parser.parse("ext:PDF,.docx kind:image,doc in:~/Documents/ in:\"~/My Files\" name:2024 content:lease")
        #expect(query.extensions == ["pdf", "docx"])
        #expect(query.kinds == [.image, .document])
        #expect(query.folders == ["/Users/test/Documents", "/Users/test/My Files"])
        #expect(query.nameTerms == ["2024"])
        #expect(query.contentTerms == ["lease"])
        #expect(query.terms.isEmpty)
    }

    @Test func sizes() {
        #expect(parser.parse("size:>10mb").minSize == Int64(10 * 1_048_576))
        #expect(parser.parse("size:<1k").maxSize == Int64(1024))
        let range = parser.parse("size:1mb..5mb")
        #expect(range.minSize == Int64(1_048_576) && range.maxSize == Int64(5 * 1_048_576))
        let about = parser.parse("size:100")
        #expect(about.minSize == 90 && about.maxSize == 110)
        #expect(parser.parse("size:huge").terms == ["size:huge"])
    }

    @Test func relativeAndCalendarDates() {
        let week = parser.parse("modified:<7d").modified!
        #expect(week.start == calendar.date(byAdding: .day, value: -7, to: now))
        let older = parser.parse("modified:>1y").modified!
        #expect(older.end == calendar.date(byAdding: .year, value: -1, to: now))
        let march = parser.parse("modified:2026-03").modified!
        #expect(march.start == date(2026, 3, 1) && march.end == date(2026, 4, 1))
        let spring = parser.parse("created:2026-03..2026-05").created!
        #expect(spring.start == date(2026, 3, 1) && spring.end == date(2026, 6, 1))
        let before = parser.parse("modified:<2025").modified!
        #expect(before.end == date(2025, 1, 1))
        let today = parser.parse("modified:today").modified!
        #expect(today.start == date(2026, 9, 27))
    }

    @Test func booleansAndUnknownKeys() {
        let query = parser.parse("hidden:no cloud:yes https://example.com")
        #expect(query.hidden == false)
        #expect(query.cloudOnly == true)
        #expect(query.terms == ["https://example.com"])
    }

    @Test func naturalLanguageDatesAreComputedInSwift() {
        let nl = NaturalLanguageQuery(now: now, calendar: calendar)
        let spring = nl.dateInterval(.spring, year: nil, month: nil)!
        #expect(spring.start == date(2026, 3, 1) && spring.end == date(2026, 6, 1))
        let winter = nl.dateInterval(.winter, year: nil, month: nil)!
        #expect(winter.start == date(2025, 12, 1) && winter.end == date(2026, 3, 1))
        let december = nl.dateInterval(.specificMonth, year: nil, month: 12)!
        #expect(december.start == date(2025, 12, 1))
        let lastYear = nl.dateInterval(.lastYear, year: nil, month: nil)!
        #expect(lastYear.start == date(2025, 1, 1) && lastYear.end == date(2026, 1, 1))
        #expect(nl.dateInterval(.specificMonth, year: nil, month: 13) == nil)
    }
}

extension QueryParserTests {
    @Test func excludedFolders() {
        let query = parser.parse("notes -in:~/Library -draft")
        #expect(query.excludedFolders == ["/Users/test/Library"])
        #expect(query.excludedTerms == ["draft"])
    }

    @Test func formatterRoundTrips() {
        let text = #"invoice "rent receipt" name:2024 -draft ext:docx,pdf kind:document size:>10mb modified:2026-03-01..2026-05-31 in:~/Documents -in:~/Library hidden:no"#
        let parsed = parser.parse(text)
        let formatted = QueryFormatter(calendar: calendar, home: "/Users/test").string(from: parsed)
        #expect(parser.parse(formatted) == parsed)
        let open = parser.parse("modified:<2025 created:>2026-01-15")
        #expect(parser.parse(QueryFormatter(calendar: calendar, home: "/Users/test").string(from: open)) == open)
    }
}

extension QueryParserTests {
    @Test func namedFormatsWinOverBroadKinds() {
        let nl = NaturalLanguageQuery(now: now, calendar: calendar)
        let parsed = ParsedRequest(
            keywords: ["invoices"], fileKinds: [.document], extensions: ["PDF"], datePeriod: .spring,
            dateField: .modified, year: nil, month: nil, minimumSizeMegabytes: nil, maximumSizeMegabytes: nil
        )
        let interpretation = nl.interpretation(of: parsed)
        #expect(interpretation.query.extensions == ["pdf"])
        #expect(interpretation.query.kinds.isEmpty)
        #expect(interpretation.summary.contains("May 31"))
    }
}
