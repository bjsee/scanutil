import ArchiveKit
import CoreGraphics
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

/// Scans löschen: das Archiv, jede Serie, die Miniaturleiste und die Auswahl müssen danach zusammenpassen.
@MainActor
@Suite("Scans löschen im Modell")
struct ScanDeletionModelTests {
    nonisolated private static let none: @Sendable (CGImage) -> AnalysisResult = { _ in AnalysisResult(corrections: Corrections(), warnings: []) }

    private func makeModel(disposal: ScanDisposal = .permanent) async -> (AppModel, ArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-sdel-\(UUID().uuidString)")
        let store = ArchiveStore(root: dir)
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: store, thumbnailSize: 64, analyze: Self.none,
                             analyzeBook: { _ in BookAnalysisResult(left: Corrections(), right: Corrections(), warnings: []) },
                             sound: SilentSound(), defaults: nil, scanDisposal: disposal)
        await model.connect()
        return (model, store, dir)
    }

    private func record(_ model: AppModel, title: String, scans: Int, book: Bool = false) async throws -> UUID {
        model.startSeries(title: title, book: book)
        let id = try #require(model.series?.id)
        for _ in 0..<scans { await model.scan() }
        model.endSeries()
        return id
    }

    @Test func aDeletedScanDisappearsEverywhere() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = try await record(model, title: "Buch", scans: 3)
        let victim = try #require(model.scans.map(\.id).dropFirst().first)    // der mittlere
        let neighbours = model.scans.map(\.id).filter { $0 != victim }

        await model.deleteScan(id: victim)
        #expect(!model.scans.map(\.id).contains(victim), "Aus der Miniaturleiste")
        #expect(Set(model.scans.map(\.id)) == Set(neighbours))
        #expect(!(try store.allRecords().map(\.id).contains(victim)), "Aus dem Archiv")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("originals/\(victim.uuidString.lowercased()).png").path))
        #expect(model.savedDocuments.first { $0.id == id }?.pages.count == 2, "Aus der Serie")
        #expect(try store.loadDocument(id: id).pages.count == 2, "Und aus der Datei der Serie")
        #expect(try store.loadDocument(id: id).pages.allSatisfy { $0.scanID != victim })
        #expect(model.openedDocument?.pages.count == 2, "Die angesehene Serie ist aktuell")
        await model.disconnect()
    }

    @Test func theSelectionMovesOnWhenTheSelectedScanIsDeleted() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await record(model, title: "A", scans: 3)
        let selected = try #require(model.selectedID)
        await model.deleteScan(id: selected)
        #expect(model.selectedID != selected && model.selectedID == model.scans.first?.id)
        // Der letzte Scan: danach ist nichts mehr ausgewählt.
        for item in model.scans { await model.deleteScan(id: item.id) }
        #expect(model.scans.isEmpty && model.selectedID == nil)
        await model.disconnect()
    }

    @Test func aBookScanTakesBothPagesWithIt() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = try await record(model, title: "Buch", scans: 2, book: true)
        #expect(model.savedDocuments.first?.pages.count == 4)
        let victim = try #require(model.scans.first?.id)
        let pageIDs = model.pages(of: victim).map(\.id)
        #expect(pageIDs.count == 2)
        await model.deleteScan(id: victim)
        #expect(try store.loadDocument(id: id).pages.count == 2, "Beide Seiten der Doppelseite sind weg")
        for page in pageIDs { #expect(model.pagePreviews[page] == nil) }
        await model.disconnect()
    }

    @Test func aScanInTheRunningSeriesCanBeDeletedAndTheSeriesGoesOn() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Läuft")
        await model.scan(); await model.scan()
        let id = try #require(model.series?.id)
        let victim = try #require(model.scans.first?.id)      // die verwackelte letzte Aufnahme
        await model.deleteScan(id: victim)
        #expect(model.series?.pages.count == 1 && model.isSeriesActive)
        await model.scan()
        #expect(model.series?.pages.count == 2, "Die Serie nimmt weiter auf")
        #expect(try store.loadDocument(id: id).pages.count == 2)
        await model.disconnect()
    }

    @Test func aScanInTwoSeriesDisappearsFromBoth() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await record(model, title: "A", scans: 2)
        let b = try await record(model, title: "B", scans: 0)
        let shared = try #require(model.savedDocuments.first { $0.id == a }?.pages.first?.scanID)
        // Dieselbe Aufnahme zusätzlich in Serie B.
        var docB = try #require(model.savedDocuments.first { $0.id == b })
        docB.append(DocumentPage(scanID: shared))
        try store.saveDocument(docB)
        let again = AppModel(scanner: MockScanner(previewsEnabled: false), store: store, thumbnailSize: 64, analyze: Self.none,
                             sound: SilentSound(), defaults: nil)
        await again.loadArchive()
        #expect(again.documents(containing: shared).count == 2)
        await again.deleteScan(id: shared)
        #expect(again.documents(containing: shared).isEmpty)
        #expect(try store.loadDocument(id: a).pages.count == 1)
        #expect(try store.loadDocument(id: b).pages.isEmpty)
        await model.disconnect()
    }

    @Test func deletingASeriesWithItsScansTakesTheScans() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await record(model, title: "Bleibt", scans: 1)
        let weg = try await record(model, title: "Weg samt Scans", scans: 3)
        #expect(try store.allRecords().count == 4)
        await model.deleteDocument(id: weg, withScans: true)
        #expect(model.savedDocuments.map(\.title) == ["Bleibt"])
        let remaining = try store.allRecords().count
        #expect(remaining == 1, "Drei Scans sind gelöscht, der der anderen Serie bleibt")
        #expect(try store.unassignedScans().isEmpty)
        await model.disconnect()
    }

    @Test func deletingASeriesWithoutItsScansKeepsThem() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = try await record(model, title: "Nur die Serie", scans: 2)
        await model.deleteDocument(id: id, withScans: false)
        let records = try store.allRecords().count, unassigned = try store.unassignedScans().count
        #expect(records == 2 && unassigned == 2)
        await model.disconnect()
    }

    @Test func theLogSaysWhetherTheScansCanBePutBack() async throws {
        let moved = LockedURLs()
        let trashLike = ScanDisposal(isRecoverable: true) { url in moved.add(url); try FileManager.default.removeItem(at: url) }
        let (model, _, dir) = await makeModel(disposal: trashLike); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.scansAreRecoverable)
        _ = try await record(model, title: "A", scans: 1)
        await model.deleteScan(id: try #require(model.scans.first?.id))
        let note = try #require(model.log.first)
        #expect(note.level == .info && note.text.contains("Papierkorb") && note.text.contains("Zurücklegen"), "Meldung: \(note.text)")
        // Original und Eintrag immer, die Korrekturen nur, wenn die Analyse sie schon geschrieben hat.
        #expect((2...3).contains(moved.count), "Entsorgte Dateien: \(moved.count)")
        #expect(moved.contains { $0.pathExtension == "png" } && moved.contains { $0.deletingLastPathComponent().lastPathComponent == "records" })
        await model.disconnect()

        let (plain, _, dir2) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir2) }
        #expect(!plain.scansAreRecoverable)
        _ = try await record(plain, title: "B", scans: 1)
        await plain.deleteScan(id: try #require(plain.scans.first?.id))
        #expect(plain.log.first?.text == "1 Scan gelöscht.")
        await plain.disconnect()
    }

    @Test func aFailureOnOneScanKeepsTheOthersDeletedAndReportsTheError() async throws {
        struct Broken: Error, LocalizedError { var errorDescription: String? { "Papierkorb nicht erreichbar" } }
        let failing = ScanDisposal { url in
            if url.lastPathComponent.hasPrefix("0") { throw Broken() }   // Dateien, deren Kennung mit 0 beginnt
            try FileManager.default.removeItem(at: url)
        }
        let (model, store, dir) = await makeModel(disposal: failing); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await record(model, title: "A", scans: 6)
        let ids = model.scans.map(\.id)
        let doomed = ids.filter { !$0.uuidString.lowercased().hasPrefix("0") }
        let stuck = ids.filter { $0.uuidString.lowercased().hasPrefix("0") }
        try #require(!doomed.isEmpty, "Der Zufall wählte nur Kennungen mit 0")
        for id in ids { await model.deleteScan(id: id) }
        #expect(Set(try store.allRecords().map(\.id)) == Set(stuck), "Nur die, deren Entsorgung scheiterte, bleiben")
        if !stuck.isEmpty { #expect(model.log.contains { $0.level == .error && $0.text.contains("Papierkorb nicht erreichbar") }) }
        #expect(model.savedDocuments.first?.pages.count == stuck.count, "Das Dokument verweist nur noch auf vorhandene Scans")
        await model.disconnect()
    }

    @Test func deletingAnUnknownScanChangesNothing() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await record(model, title: "A", scans: 2)
        let logged = model.log.count
        await model.deleteScan(id: UUID())
        let stored = try store.allRecords().count
        #expect(model.scans.count == 2 && stored == 2)
        #expect(model.log.first?.level == .error, "Der Fehler wird gemeldet")
        #expect(model.log.count == logged + 1)
        await model.disconnect()
    }

    @Test func anAnalysisThatFinishesAfterTheDeletionWritesNothing() async throws {
        // Die Analyse braucht Zeit. Wird der Scan davor gelöscht, darf sie keine Korrekturdatei für ihn anlegen.
        let slow: @Sendable (CGImage) -> AnalysisResult = { _ in
            Thread.sleep(forTimeInterval: 0.4)
            var c = Corrections(); c.setRotation(degrees: 2)
            return AnalysisResult(corrections: c, warnings: [])
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-sdel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveStore(root: dir)
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: store, thumbnailSize: 64, analyze: slow,
                             sound: SilentSound(), defaults: nil)
        await model.connect()
        await model.scan()
        let id = try #require(model.scans.first?.id)
        await model.deleteScan(id: id)
        try await Task.sleep(for: .milliseconds(900))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("corrections").path)) ?? []
        #expect(files.isEmpty, "Für den gelöschten Scan wurde nachträglich noch \(files) geschrieben")
        #expect(model.scans.isEmpty)
        await model.disconnect()
    }

    @Test func theFullResolutionCacheForgetsADeletedScan() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await record(model, title: "A", scans: 1)
        let id = try #require(model.scans.first?.id)
        #expect(await model.fullResolutionImage(scanID: id) != nil)
        await model.deleteScan(id: id)
        #expect(await model.fullResolutionImage(scanID: id) == nil)
        await model.disconnect()
    }
}

/// Zählt die entsorgten Dateien.
private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
    var count: Int { lock.withLock { urls.count } }
    func contains(_ predicate: (URL) -> Bool) -> Bool { lock.withLock { urls.contains(where: predicate) } }
}
