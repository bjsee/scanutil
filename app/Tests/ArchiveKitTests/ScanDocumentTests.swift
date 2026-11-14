import Testing
import Foundation
import ScannerKit
import ImagingKit
@testable import ArchiveKit

@Suite("ScanDocument")
struct ScanDocumentTests {
    private func page(_ region: PageRegion = .whole) -> DocumentPage {
        DocumentPage(scanID: UUID(), region: region)
    }

    private func titles(_ doc: ScanDocument) -> [UUID] { doc.pages.map(\.id) }

    @Test func appendKeepsOrderAndCountsRevision() {
        var doc = ScanDocument(title: "Chronik")
        let a = page(), b = page()
        doc.append(a); doc.append(b)
        #expect(titles(doc) == [a.id, b.id])
        #expect(doc.revision == 2)
    }

    @Test func insertClampsIndex() {
        var doc = ScanDocument(title: "T")
        let a = page(), b = page(), c = page()
        doc.append(a)
        doc.insert(b, at: 99)
        doc.insert(c, at: -5)
        #expect(titles(doc) == [c.id, a.id, b.id])
    }

    @Test func removeKeepsOthersAndReportsMissing() {
        var doc = ScanDocument(title: "T")
        let a = page(), b = page()
        doc.append(a); doc.append(b)
        let removed = doc.removePage(id: a.id)
        #expect(removed == a)
        #expect(titles(doc) == [b.id])
        let before = doc.revision
        let missing = doc.removePage(id: UUID())
        #expect(missing == nil)
        #expect(doc.revision == before)
    }

    @Test func moveReorders() {
        var doc = ScanDocument(title: "T")
        let a = page(), b = page(), c = page()
        [a, b, c].forEach { doc.append($0) }
        let moved = doc.movePage(id: c.id, to: 0)
        #expect(moved)
        #expect(titles(doc) == [c.id, a.id, b.id])
        let movedMissing = doc.movePage(id: UUID(), to: 0)
        #expect(movedMissing == false)
    }

    @Test func replaceKeepsPosition() {
        var doc = ScanDocument(title: "T")
        let a = page(), b = page(), c = page()
        [a, b, c].forEach { doc.append($0) }
        let neu = page()
        let replaced = doc.replacePage(id: b.id, with: neu)
        #expect(replaced)
        #expect(titles(doc) == [a.id, neu.id, c.id])
    }

    @Test func twoPagesOfOneScanHaveOwnCorrections() {
        let scan = UUID()
        var doc = ScanDocument(title: "Buch")
        let left = DocumentPage(scanID: scan, region: .left)
        let right = DocumentPage(scanID: scan, region: .right)
        doc.append(left); doc.append(right)
        doc.updateCorrections(pageID: left.id) { $0.setRotation(degrees: 1.5) }
        #expect(doc.page(id: left.id)?.corrections.rotation.degrees == 1.5)
        #expect(doc.page(id: right.id)?.corrections.rotation.degrees == 0)
        let changedMissing = doc.updateCorrections(pageID: UUID()) { _ in }
        #expect(changedMissing == false)
    }
}

@Suite("Dokumentspeicher")
struct DocumentStorageTests {
    private func makeStore() -> (ArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-doc-\(UUID().uuidString)")
        return (ArchiveStore(root: dir), dir)
    }

    private func storeScan(_ store: ArchiveStore) async throws -> ScanRecord {
        let session = try await MockScanner().openSession(format: ScanFormat(width: 320, height: 240), settings: .archival)
        let capture = try await session.capture()
        await session.close()
        return try store.store(capture)
    }

    @Test func roundTrips() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let scan = try await storeScan(store)
        var doc = ScanDocument(title: "Chronik 1524", metadata: .init(author: "N. N.", dateText: "um 1900", keywords: ["Mulsum"]))
        var p = DocumentPage(scanID: scan.id, region: .left, label: "iv")
        p.corrections.setRotation(degrees: -0.7)
        doc.append(p)
        try store.saveDocument(doc)
        let loaded = try store.loadDocument(id: doc.id)
        expectSame(loaded, doc)
        let all = try store.allDocuments()
        #expect(all.count == 1)
        if let first = all.first { expectSame(first, doc) }
    }

    /// Zeitpunkte sind als ISO 8601 mit Millisekunden gespeichert, exakte Gleichheit von `Date` gilt nicht.
    /// Die Abweichung kann knapp über einer Millisekunde liegen (gemessen: 0,0010000467), daher zwei Millisekunden Toleranz.
    private func expectSame(_ a: ScanDocument, _ b: ScanDocument, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.id == b.id, sourceLocation: sourceLocation)
        #expect(a.title == b.title, sourceLocation: sourceLocation)
        #expect(a.metadata == b.metadata, sourceLocation: sourceLocation)
        #expect(a.pages == b.pages, sourceLocation: sourceLocation)
        #expect(a.revision == b.revision, sourceLocation: sourceLocation)
        #expect(abs(a.createdAt.timeIntervalSince(b.createdAt)) < 0.002, sourceLocation: sourceLocation)
    }

    @Test func rejectsPageWithUnknownScan() throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        var doc = ScanDocument(title: "T")
        doc.append(DocumentPage(scanID: UUID()))
        #expect(throws: ArchiveError.self) { try store.saveDocument(doc) }
        #expect(try store.allDocuments().isEmpty)
    }

    @Test func missingDocumentThrows() {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        #expect(throws: ArchiveError.documentNotFound(id)) { _ = try store.loadDocument(id: id) }
    }

    @Test func removedPageLeavesScanUnassigned() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let kept = try await storeScan(store), dropped = try await storeScan(store)
        var doc = ScanDocument(title: "T")
        let a = DocumentPage(scanID: kept.id), b = DocumentPage(scanID: dropped.id)
        doc.append(a); doc.append(b)
        try store.saveDocument(doc)
        #expect(try store.unassignedScans().isEmpty)

        doc.removePage(id: b.id)
        try store.saveDocument(doc)
        #expect(try store.unassignedScans().map(\.id) == [dropped.id])
        #expect(try store.verify(dropped))   // das Original bleibt unangetastet
    }

    @Test func secondSaveReplacesFile() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        var doc = ScanDocument(title: "alt")
        try store.saveDocument(doc)
        doc.title = "neu"
        try store.saveDocument(doc)
        #expect(try store.loadDocument(id: doc.id).title == "neu")
    }
}

@Suite("Dokument löschen")
struct DocumentDeletionTests {
    private func makeStore() -> (ArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-del-\(UUID().uuidString)")
        return (ArchiveStore(root: dir), dir)
    }

    private func storeScan(_ store: ArchiveStore) async throws -> ScanRecord {
        let session = try await MockScanner().openSession(format: ScanFormat(width: 320, height: 240), settings: .archival)
        let capture = try await session.capture()
        await session.close()
        return try store.store(capture)
    }

    @Test func removesTheDocumentButNeverTheOriginals() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let scan = try await storeScan(store)
        var doc = ScanDocument(title: "Weg")
        doc.append(DocumentPage(scanID: scan.id))
        try store.saveDocument(doc)

        try store.deleteDocument(id: doc.id)
        #expect(try store.allDocuments().isEmpty)
        #expect(throws: ArchiveError.documentNotFound(doc.id)) { _ = try store.loadDocument(id: doc.id) }
        // Das Original ist unberührt, geprüft und wieder frei.
        #expect(FileManager.default.fileExists(atPath: store.originalURL(for: scan).path))
        #expect(try store.verify(scan))
        #expect(try store.unassignedScans().map(\.id) == [scan.id])
    }

    @Test func deletingAnUnknownDocumentThrows() {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        #expect(throws: ArchiveError.documentNotFound(id)) { try store.deleteDocument(id: id) }
    }

    @Test func otherDocumentsStayWhenOneIsDeleted() throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = ScanDocument(title: "A"), b = ScanDocument(title: "B")
        try store.saveDocument(a); try store.saveDocument(b)
        try store.deleteDocument(id: a.id)
        #expect(try store.allDocuments().map(\.id) == [b.id])
    }

    // MARK: Zwei Scans zu einer Seite

    private func twoPages() -> (ScanDocument, DocumentPage, DocumentPage, DocumentPage) {
        let a = DocumentPage(scanID: UUID()), b = DocumentPage(scanID: UUID()), c = DocumentPage(scanID: UUID())
        var doc = ScanDocument(title: "Plan")
        doc.append(a); doc.append(b); doc.append(c)
        return (doc, a, b, c)
    }

    @Test func joiningTakesTheSecondScanIntoTheFirstPageAndRemovesTheSecondPage() {
        var (doc, a, b, c) = twoPages()
        var marked = b.corrections; marked.setRotation(degrees: 1.5)
        doc.pages[1].corrections = marked
        let r1 = doc.joinPages(first: a.id, second: b.id)
        #expect(r1)
        #expect(doc.pages.map(\.id) == [a.id, c.id], "Die zweite Seite ist aus der Liste")
        let joined = try! #require(doc.pages[0].joined)
        #expect(joined.scanID == b.scanID && joined.corrections.rotation.degrees == 1.5, "Der zweite Teil behält seine Korrekturen")
        #expect(joined.gap == 0 && joined.shift == 0)
        #expect(doc.pages[0].scanIDs == [a.scanID, b.scanID] && doc.pages[0].uses(scan: b.scanID) && !doc.pages[1].uses(scan: b.scanID))
    }

    @Test func joiningRefusesWhatMakesNoSense() {
        var (doc, a, b, _) = twoPages()
        let r2 = doc.joinPages(first: a.id, second: a.id)
        #expect(!r2, "Nicht mit sich selbst")
        let r3 = doc.joinPages(first: a.id, second: UUID())
        #expect(!r3, "Unbekannte Seite")
        var halves = ScanDocument(title: "Buch")
        let scan = UUID()
        halves.append(DocumentPage(scanID: scan, region: .left)); halves.append(DocumentPage(scanID: scan, region: .right))
        let r4 = halves.joinPages(first: halves.pages[0].id, second: halves.pages[1].id)
        #expect(!r4, "Buchhälften werden nicht verbunden")
        let same = DocumentPage(scanID: a.scanID)
        doc.append(same)
        let r5 = doc.joinPages(first: a.id, second: same.id)
        #expect(!r5, "Zwei Seiten desselben Scans")
        let r6 = doc.joinPages(first: a.id, second: b.id)
        #expect(r6)
        let r7 = doc.joinPages(first: a.id, second: doc.pages[1].id)
        #expect(!r7, "Eine schon verbundene Seite nimmt keinen dritten Teil")
    }

    @Test func unjoiningPutsTheSecondPartBackAsItsOwnPageRightBehind() {
        var (doc, a, b, c) = twoPages()
        _ = doc.joinPages(first: a.id, second: b.id)
        doc.pages[0].joined?.corrections.setRotation(degrees: -0.7)
        let r8 = doc.unjoinPage(id: a.id)
        #expect(r8)
        #expect(doc.pages.count == 3 && doc.pages[0].id == a.id && doc.pages[2].id == c.id)
        #expect(doc.pages[1].scanID == b.scanID && doc.pages[1].corrections.rotation.degrees == -0.7, "Mit seinen Korrekturen, hinter der ersten")
        #expect(doc.pages[0].joined == nil)
        let r9 = doc.unjoinPage(id: a.id)
        #expect(!r9, "Eine nicht verbundene Seite lässt sich nicht trennen")
    }

    @Test func swappingExchangesLeftAndRightAndKeepsEachOnesCorrections() {
        var (doc, a, b, _) = twoPages()
        doc.pages[0].corrections.setRotation(degrees: 1)
        doc.pages[1].corrections.setRotation(degrees: 2)
        _ = doc.joinPages(first: a.id, second: b.id)
        doc.pages[0].joined?.shift = 0.03
        let r10 = doc.swapJoinedParts(id: a.id)
        #expect(r10)
        #expect(doc.pages[0].scanID == b.scanID && doc.pages[0].corrections.rotation.degrees == 2)
        #expect(doc.pages[0].joined?.scanID == a.scanID && doc.pages[0].joined?.corrections.rotation.degrees == 1)
        #expect(doc.pages[0].joined?.shift == -0.03, "Die Höhenverschiebung kehrt sich um, damit dieselben Stellen zusammenpassen")
    }

    @Test func aJoinedPageSurvivesJSONAndOldFilesHaveNone_andReviewedFollowsBothParts() throws {
        var (doc, a, b, _) = twoPages()
        _ = doc.joinPages(first: a.id, second: b.id)
        let data = try JSONEncoder().encode(doc)
        #expect(try JSONDecoder().decode(ScanDocument.self, from: data) == doc)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var pages = try #require(object["pages"] as? [[String: Any]])
        pages[0].removeValue(forKey: "joined"); object["pages"] = pages
        #expect(try JSONDecoder().decode(ScanDocument.self, from: JSONSerialization.data(withJSONObject: object)).pages[0].joined == nil)

        doc.pages[0].reviewedKey = doc.pages[0].reviewKey
        #expect(doc.pages[0].isReviewed)
        doc.pages[0].joined?.corrections.setRotation(degrees: 0.4)
        #expect(!doc.pages[0].isReviewed, "Ändert sich der zweite Teil, ist die Seite wieder ungeprüft")
        doc.pages[0].reviewedKey = doc.pages[0].reviewKey
        doc.pages[0].joined?.gap = 0.01
        #expect(!doc.pages[0].isReviewed, "Auch die Naht gehört dazu")
    }
}
