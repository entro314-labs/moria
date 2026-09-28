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

extension QueryParserTests {
    @Test func chipsDescribeFiltersAndRemoveCleanly() {
        let text = #"invoice kind:pdf -kind:image modified:<7d in:"~/My Files" -draft"#
        let chips = parser.chips(for: text)
        #expect(chips.map(\.label) == ["PDF", "No Image", "Modified in the past 7 days", "In My Files", "Without “draft”"])
        #expect(chips.map(\.isExclusion) == [false, true, false, false, true])
        let withoutFolder = parser.removingToken(at: chips[3].tokenIndex, from: text)
        #expect(withoutFolder == "invoice kind:pdf -kind:image modified:<7d -draft")
        let keepsQuoting = parser.removingToken(at: chips[0].tokenIndex, from: text)
        #expect(parser.parse(keepsQuoting).folders == ["/Users/test/My Files"])
        #expect(parser.parse("-kind:image,video").excludedKinds == [.image, .video])
    }
}

extension QueryParserTests {
    @Test func namePatternsPathAndExtensionExclusion() {
        let query = parser.parse(#"name:report* name:*.draft name:=README name:/^IMG_\d{4}$/ path:invoices -ext:tmp,log"#)
        #expect(query.namePatterns == [.prefix("report"), .suffix(".draft"), .exact("README"), .regex(#"^IMG_\d{4}$"#)])
        #expect(query.pathContains == ["invoices"])
        #expect(query.excludedExtensions == ["tmp", "log"])
        #expect(query.nameTerms.isEmpty)
        #expect(parser.parse(QueryFormatter(calendar: calendar, home: "/Users/test").string(from: query)) == query)
        #expect(parser.chips(for: "name:report* -ext:tmp").map(\.label) == ["Name begins with “report”", "Not .tmp"])
    }
}

extension QueryParserTests {
    @Test func criteriaRoundTripThroughQueryText() {
        let text = #"invoice "rent receipt" -draft name:report* name:/^IMG_\d+$/ ext:pdf,docx -kind:folder content:lease path:taxes in:/Users/test/Documents -in:/Users/test/Library size:>10mb size:1mb..5mb modified:<7d created:2026-03..2026-05 modified:>2025-01-01 hidden:no cloud:yes"#
        let criteria = Criterion.criteria(from: text, home: "/Users/test")
        #expect(criteria.map(\.attribute) == [.words, .words, .words, .name, .name, .ext, .kind, .contents, .path, .folder, .folder,
                                               .size, .size, .modified, .created, .modified, .hidden, .cloud])
        #expect(criteria.map(\.op) == [.contains, .containsPhrase, .doesNotContain, .beginsWith, .matchesRegex, .is, .isNot,
                                        .contains, .contains, .is, .isNot, .greaterThan, .between, .withinLast, .between, .after,
                                        .exclude, .include])
        let rebuilt = Criterion.query(from: criteria)
        #expect(parser.parse(rebuilt) == parser.parse(text))
        // `-content:` is not a filter; it must not turn into "Contents contains".
        #expect(Criterion.criteria(from: "-content:lease -text:lease", home: "/Users/test").map(\.op) == [.doesNotContain, .doesNotContain])
        #expect(Criterion(attribute: .name, op: .beginsWith, value: "").token == nil)
        #expect(Criterion(attribute: .size, op: .between, value: "1", unit: "mb").token == nil)
    }
}

extension QueryParserTests {
    @Test func settingsFromOlderVersionsLoadWithDefaults() throws {
        let old = #"{"roots":["/Users/test"],"ocrImages":false}"#
        let settings = try JSONDecoder().decode(MoriaSettings.self, from: Data(old.utf8))
        #expect(settings.roots == ["/Users/test"])
        #expect(settings.ocrImages == false)
        #expect(settings.maxContentKilobytes == MoriaSettings.defaults().maxContentKilobytes)
    }
}

extension QueryParserTests {
    @Test func similarNamesAFileAndRoundTrips() {
        let query = parser.parse(#"lease similar:"~/My Files/offer.pdf" kind:pdf"#)
        #expect(query.similarTo == "/Users/test/My Files/offer.pdf")
        #expect(query.terms == ["lease"])
        #expect(!query.isEmpty)
        #expect(parser.parse("similar:~/a.pdf").isEmpty == false)
        let formatter = QueryFormatter(calendar: calendar, home: "/Users/test")
        #expect(parser.parse(formatter.string(from: query)) == query)
        #expect(parser.chips(for: "similar:~/Documents/offer.pdf").map(\.label) == ["Similar to offer.pdf"])
        let criteria = Criterion.criteria(from: #"similar:"~/My Files/offer.pdf""#, home: "/Users/test")
        #expect(criteria.map(\.attribute) == [.similar])
        #expect(parser.parse(Criterion.query(from: criteria)).similarTo == "/Users/test/My Files/offer.pdf")
    }
}

extension QueryParserTests {
    @Test func tagsParseFormatAndDescribe() throws {
        let query = parser.parse(#"invoice tag:Red,"Needs Review" -tag:done"#)
        #expect(query.tags == ["Red", "Needs Review"])
        #expect(query.excludedTags == ["done"])
        #expect(query.hasFilters)
        #expect(parser.parse(QueryFormatter(calendar: calendar, home: "/Users/test").string(from: query)) == query)
        #expect(parser.chips(for: "tag:red -tag:done").map(\.label) == ["Tagged red", "Not tagged done"])
        let criteria = Criterion.criteria(from: #"tag:"Needs Review" -tag:done"#, home: "/Users/test")
        #expect(criteria.map(\.attribute) == [.tag, .tag])
        #expect(criteria.map(\.op) == [.is, .isNot])
        #expect(parser.parse(Criterion.query(from: criteria)).tags == ["Needs Review"])

        // Finder stores "Name\n<color>" entries in a binary property list.
        let stored = try PropertyListSerialization.data(fromPropertyList: ["Red\n6", "Work"], format: .binary, options: 0)
        #expect(FinderTags.parse(stored) == ["Red", "Work"])
        #expect(FinderTags.names(fromStored: FinderTags.stored(["Red", "Work"])) == ["Red", "Work"])
        #expect(FinderTags.stored([]) == nil)
    }
}

extension QueryParserTests {
    @Test func takenDurationAndAuthor() {
        let query = parser.parse(#"beach taken:2024-07 duration:>10m author:"Maria P""#)
        #expect(query.taken == DateInterval(start: date(2024, 7, 1), end: date(2024, 8, 1)))
        #expect(query.minDuration == 600 && query.maxDuration == nil)
        #expect(query.authors == ["Maria P"])
        #expect(parser.parse("duration:1m..1h").minDuration == 60)
        #expect(parser.parse("duration:1m..1h").maxDuration == 3600)
        #expect(parser.parse("duration:<2:30").maxDuration == 150)
        #expect(parser.parse("duration:long").terms == ["duration:long"])
        let formatter = QueryFormatter(calendar: calendar, home: "/Users/test")
        #expect(parser.parse(formatter.string(from: query)) == query)
        #expect(parser.chips(for: "duration:>10m author:smith").map(\.label) == ["Longer than 10 min", "By smith"])
        let criteria = Criterion.criteria(from: #"taken:<30d duration:1m..5m author:"Maria P""#, home: "/Users/test")
        #expect(criteria.map(\.attribute) == [.taken, .duration, .author])
        #expect(criteria.map(\.op) == [.withinLast, .between, .contains])
        let rebuilt = parser.parse(Criterion.query(from: criteria))
        #expect(rebuilt.minDuration == 60 && rebuilt.maxDuration == 300 && rebuilt.authors == ["Maria P"] && rebuilt.taken != nil)
    }
}
