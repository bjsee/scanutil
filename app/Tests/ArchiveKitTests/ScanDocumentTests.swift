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
}
