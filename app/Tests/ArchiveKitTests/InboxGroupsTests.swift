import Foundation
import Testing
@testable import ArchiveKit

@Suite("Schnellablage: Dokumente aus Seiten")
struct InboxGroupsTests {
    private func inbox(_ count: Int) -> ScanDocument {
        var doc = ScanDocument(title: "Schnellablage", inbox: InboxInfo())
        for _ in 0..<count { doc.append(DocumentPage(scanID: UUID())) }
        return doc
    }

    @Test func everyPageIsItsOwnDocumentByDefault() {
        let doc = inbox(3)
        #expect(doc.groups.count == 3)
        #expect(doc.groups.map(\.pageIDs) == doc.pages.map { [$0.id] })
        #expect(doc.isInbox)
    }

    @Test func aSeriesIsNotAnInbox() { #expect(!ScanDocument(title: "S").isInbox) }

    @Test func mergingJoinsAPageWithTheDocumentBefore() throws {
        var doc = inbox(3)
        let ids = doc.pages.map(\.id)
        let merged = doc.mergeWithPrevious(pageID: ids[1])
        #expect(merged)
        #expect(doc.groups.count == 2)
        #expect(doc.groups[0].pageIDs == [ids[0], ids[1]])
        #expect(doc.groups[1].pageIDs == [ids[2]])
    }

    @Test func mergingTheFirstDocumentDoesNothing() {
        var doc = inbox(2)
        let rev = doc.revision
        let merged = doc.mergeWithPrevious(pageID: doc.pages[0].id)
        #expect(!merged)
        #expect(doc.revision == rev)
    }

    @Test func mergingAWholeDocumentTakesAllItsPagesAlong() {
        var doc = inbox(4)
        let ids = doc.pages.map(\.id)
        _ = doc.mergeWithPrevious(pageID: ids[3])             // [0] [1] [2,3]
        _ = doc.mergeWithPrevious(pageID: ids[3])             // [0] [1,2,3]: der ganze hintere Block wandert
        #expect(doc.groups.map(\.pageIDs) == [[ids[0]], [ids[1], ids[2], ids[3]]])
    }

    @Test func splittingCutsTheDocumentBeforeThePage() {
        var doc = inbox(3)
        let ids = doc.pages.map(\.id)
        _ = doc.mergeWithPrevious(pageID: ids[1]); _ = doc.mergeWithPrevious(pageID: ids[2])
        #expect(doc.groups.count == 1)
        let cut = doc.splitBefore(pageID: ids[1])
        #expect(cut)
        #expect(doc.groups.map(\.pageIDs) == [[ids[0]], [ids[1], ids[2]]])
        let again = doc.splitBefore(pageID: ids[1])
        #expect(!again, "Die erste Seite eines Dokuments lässt sich nicht abtrennen")
    }

    @Test func namesFollowTheirDocumentAndTheMergedOnesDisappear() {
        var doc = inbox(2)
        let ids = doc.pages.map(\.id)
        doc.setName("  Tierarztpraxis ", of: doc.groups[0].id)
        doc.setName("Stadtwerke", of: doc.groups[1].id)
        #expect(doc.name(of: doc.groups[0]) == "Tierarztpraxis")
        _ = doc.mergeWithPrevious(pageID: ids[1])
        #expect(doc.groups.count == 1 && doc.name(of: doc.groups[0]) == "Tierarztpraxis")
        #expect(doc.inbox?.names.count == 1, "Der Name des hinteren Dokuments fällt weg")
        doc.setName("   ", of: doc.groups[0].id)
        #expect(doc.name(of: doc.groups[0]) == nil, "Leer entfernt den Namen")
    }

    @Test func namesAreIgnoredOutsideAnInbox() {
        var doc = ScanDocument(title: "Serie")
        doc.append(DocumentPage(scanID: UUID()))
        doc.setName("x", of: doc.groups[0].id)
        #expect(doc.inbox == nil)
    }

    @Test func theGroupsSurviveSavingAndOlderDocumentsStillLoad() throws {
        var doc = inbox(2)
        _ = doc.mergeWithPrevious(pageID: doc.pages[1].id)
        doc.setName("Brief", of: doc.groups[0].id)
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(ScanDocument.self, from: data)
        #expect(back.groups == doc.groups && back.name(of: back.groups[0]) == "Brief")
        // Eine Serie von früher kennt weder inbox noch groupID.
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ScanDocument(title: "Alt"))) as? [String: Any])
        object["inbox"] = nil
        let old = try JSONDecoder().decode(ScanDocument.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!old.isInbox)
    }
}
