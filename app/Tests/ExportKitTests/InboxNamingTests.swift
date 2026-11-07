import Foundation
import Testing
@testable import ExportKit

@Suite("Schnellablage: Dateinamen")
struct InboxNamingTests {
    private func date(_ y: Int, _ m: Int) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: y, month: m, day: 15, hour: 12))!
    }
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    @Test func theNameStartsWithYearAndMonthAsFourDigits() {
        #expect(InboxNaming.prefix(for: date(2026, 11), calendar: cal) == "2611")
        #expect(InboxNaming.prefix(for: date(2027, 1), calendar: cal) == "2701", "Monat mit führender Null")
        #expect(InboxNaming.prefix(for: date(2100, 3), calendar: cal) == "0003")
        #expect(InboxNaming.fileStem(date: date(2026, 11), description: "Tierarztpraxis", calendar: cal) == "2611 Tierarztpraxis")
    }

    @Test func withoutADescriptionItIsCalledDokument() {
        #expect(InboxNaming.fileStem(date: date(2026, 11), description: nil, calendar: cal) == "2611 Dokument")
        #expect(InboxNaming.fileStem(date: date(2026, 11), description: "  ", calendar: cal) == "2611 Dokument")
        #expect(InboxNaming.fileStem(date: date(2026, 11), description: "///", calendar: cal) == "2611 Dokument")
    }

    @Test func forbiddenCharactersAndWhitespaceAreCleanedUp() {
        #expect(InboxNaming.cleanedDescription("Rechnung: Tierarzt / Dr. Meier\n") == "Rechnung Tierarzt Dr. Meier")
        #expect(InboxNaming.cleanedDescription("„Stadtwerke“  \"Mulsum\"") == "Stadtwerke Mulsum")
        #expect(InboxNaming.cleanedDescription("..versteckt..") == "versteckt")
    }

    @Test func aLongDescriptionIsCutAtAWordBoundary() {
        let long = String(repeating: "Elektroinstallation ", count: 10)
        let cut = InboxNaming.cleanedDescription(long)
        #expect(cut.count <= InboxNaming.maxDescriptionLength)
        #expect(!cut.hasSuffix(" ") && cut.hasSuffix("Elektroinstallation"))
        #expect(InboxNaming.cleanedDescription(String(repeating: "x", count: 100)).count == InboxNaming.maxDescriptionLength, "Ohne Leerzeichen wird hart gekürzt")
    }

    @Test func theHeuristicTakesTheFirstLineThatLooksLikeAName() {
        let lines = ["12.11.2026", "Tel. 04761 / 1234", "Tierarztpraxis Dr. Meier Mulsum Hauptstraße 4", "Rechnung Nr. 4711"]
        #expect(InboxNaming.heuristicDescription(from: lines) == "Tierarztpraxis Dr. Meier Mulsum", "Höchstens vier Wörter")
        #expect(InboxNaming.heuristicDescription(from: ["12.11.2026", "4711 / 0815", "--"]) == nil)
        #expect(InboxNaming.heuristicDescription(from: []) == nil)
    }
}
