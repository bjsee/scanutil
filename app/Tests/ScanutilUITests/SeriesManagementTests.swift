import ArchiveKit
import CoreGraphics
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

/// Mehrere Serien: neu beginnen oder fortsetzen, benennen, löschen, durch sie blättern.
@MainActor
@Suite("Serien verwalten")
struct SeriesManagementTests {
    nonisolated private static let none: @Sendable (CGImage) -> AnalysisResult = { _ in AnalysisResult(corrections: Corrections(), warnings: []) }

    private func tempArchive() -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-mgmt-\(UUID().uuidString)")
        return (dir, dir.appendingPathComponent("archiv"))
    }

    private func makeModel(archive: URL, scanner: MockScanner = MockScanner(previewsEnabled: false)) -> AppModel {
        AppModel(scanner: scanner, store: ArchiveStore(root: archive), thumbnailSize: 64, analyze: Self.none, sound: SilentSound(), defaults: nil)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<120 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(25)) }
        return condition()
    }

    /// Nimmt eine Serie auf und beendet sie. Gibt ihre ID zurück.
    private func record(_ model: AppModel, title: String, scans: Int, book: Bool = false) async throws -> UUID {
        model.startSeries(title: title, book: book)
        let id = try #require(model.series?.id)
        for _ in 0..<scans { await model.scan() }
        model.endSeries()
        return id
    }

    // MARK: Fortsetzen

    @Test func resumingAppendsToTheSameDocumentAfterARestart() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = makeModel(archive: archive)
        await first.connect()
        let id = try await record(first, title: "Sagenbuch", scans: 2)
        await first.disconnect()

        let model = makeModel(archive: archive)
        await model.loadArchive(); await model.connect()
        await model.resumeSeries(id: id)
        #expect(model.series?.id == id && model.series?.title == "Sagenbuch" && model.series?.pages.count == 2)
        #expect(model.scans.count == 2, "Die Miniaturleiste zeigt die Scans der Serie")
        await model.scan()
        #expect(model.series?.pages.count == 3)
        let saved = try ArchiveStore(root: archive).loadDocument(id: id)
        #expect(saved.pages.count == 3, "Die dritte Seite steht im selben Dokument auf der Platte")
        #expect(try ArchiveStore(root: archive).allDocuments().count == 1, "Es entstand kein zweites Dokument")
        #expect(model.scans.count == 3)
        await model.disconnect()
    }

    @Test func resumingABookKeepsDoublePageMode() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = makeModel(archive: archive)
        await first.connect()
        let id = try await record(first, title: "Buch", scans: 1, book: true)
        await first.disconnect()

        let model = makeModel(archive: archive)
        await model.loadArchive(); await model.connect()
        await model.resumeSeries(id: id)          // ohne Angabe: aus den Seiten abgelesen
        #expect(model.seriesIsBook)
        await model.scan()
        #expect(model.series?.pages.map(\.region) == [.left, .right, .left, .right])
        await model.disconnect()
    }

    @Test func resumingAnEmptyDocumentUsesTheGivenMode() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let id = try await record(model, title: "Leer", scans: 0)
        await model.resumeSeries(id: id, book: true)
        #expect(model.seriesIsBook)
        await model.scan()
        #expect(model.series?.pages.count == 2)
        await model.disconnect()
    }

    @Test func resumingDoesNothingWhileASeriesRunsOrForAnUnknownIDOrWithoutAScanner() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let old = try await record(model, title: "Alt", scans: 1)
        model.startSeries(title: "Läuft")
        let running = try #require(model.series?.id)
        await model.resumeSeries(id: old)
        #expect(model.series?.id == running, "Eine laufende Serie wird nicht ersetzt")
        model.endSeries()
        await model.resumeSeries(id: UUID())
        #expect(model.series == nil, "Unbekannte Serie")
        await model.disconnect()
        let off = makeModel(archive: archive, scanner: MockScanner(startsSwitchedOff: true))
        await off.loadArchive(); await off.connect()
        await off.resumeSeries(id: old)
        #expect(off.series == nil, "Ohne Scanner kann man nichts aufnehmen")
        await off.disconnect()
    }

    @Test func aNewSeriesNextToAnExistingOneKeepsBoth() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let a = try await record(model, title: "Eins", scans: 1)
        let b = try await record(model, title: "Zwei", scans: 2)
        #expect(a != b)
        #expect(Set(model.savedDocuments.map(\.id)) == [a, b])
        #expect(model.savedDocuments.first(where: { $0.id == a })?.pages.count == 1)
        #expect(model.savedDocuments.first(where: { $0.id == b })?.pages.count == 2)
        await model.disconnect()
    }

    // MARK: Benennen

    @Test func renamingChangesTheListTheFileAndTheRunningSeries() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        model.startSeries(title: "Alt")
        let id = try #require(model.series?.id)
        #expect(model.renameDocument(id: id, to: "  Sagenbuch des Landes Wursten \n"))
        #expect(model.series?.title == "Sagenbuch des Landes Wursten", "Der Name wird gekürzt")
        #expect(model.savedDocuments.first?.title == "Sagenbuch des Landes Wursten")
        #expect(try ArchiveStore(root: archive).loadDocument(id: id).title == "Sagenbuch des Landes Wursten")
        await model.disconnect()
    }

    @Test func renamingAnOpenedAndAnUnopenedSeriesWorks() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let a = try await record(model, title: "A", scans: 1)
        let b = try await record(model, title: "B", scans: 1)
        await model.openDocument(id: a)
        #expect(model.renameDocument(id: a, to: "A neu"))
        #expect(model.openedDocument?.title == "A neu")
        #expect(model.renameDocument(id: b, to: "B neu"))
        #expect(Set(model.savedDocuments.map(\.title)) == ["A neu", "B neu"])
        #expect(try ArchiveStore(root: archive).loadDocument(id: b).title == "B neu")
        await model.disconnect()
    }

    @Test func anEmptyNameIsRejectedWithAWarning() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let id = try await record(model, title: "Bleibt", scans: 0)
        #expect(!model.renameDocument(id: id, to: "   \n"))
        #expect(model.savedDocuments.first?.title == "Bleibt")
        #expect(model.log.first?.level == .warning)
        #expect(!model.renameDocument(id: UUID(), to: "Egal"), "Unbekannte Serie")
        await model.disconnect()
    }

    @Test func anEmptyTitleForANewSeriesFallsBackToTheDate() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        model.startSeries(title: "   ")
        #expect(model.series?.title.hasPrefix("Serie ") == true)
        await model.disconnect()
    }

    // MARK: Löschen

    @Test func deletingRemovesTheSeriesButKeepsEveryOriginal() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let id = try await record(model, title: "Weg damit", scans: 3)
        let store = ArchiveStore(root: archive)
        let before = try store.allRecords()
        #expect(before.count == 3)

        await model.deleteDocument(id: id)
        #expect(model.savedDocuments.isEmpty)
        #expect(try store.allDocuments().isEmpty)
        let after = try store.allRecords()
        #expect(after.map(\.id) == before.map(\.id), "Die Originale bleiben im Archiv")
        for record in after { #expect(try store.verify(record)) }
        #expect(try store.unassignedScans().count == 3, "Sie lassen sich wieder zuordnen")
        let note = try #require(model.log.first)
        #expect(note.level == .info && note.text.contains("gelöscht") && note.text.contains("Scans bleiben"))
        await model.disconnect()
    }

    @Test func deletingTheRunningSeriesEndsIt() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        model.startSeries(title: "Läuft")
        await model.scan()
        let id = try #require(model.series?.id)
        await model.deleteDocument(id: id)
        #expect(model.series == nil && !model.isSeriesActive && !model.seriesIsBook)
        #expect(model.savedDocuments.isEmpty)
        // Danach ist wieder alles möglich: eine neue Serie beginnt.
        model.startSeries(title: "Neu")
        #expect(model.isSeriesActive)
        await model.disconnect()
    }

    @Test func deletingTheOpenedSeriesClosesItAndShowsTheLatestScansAgain() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let a = try await record(model, title: "A", scans: 1)
        _ = try await record(model, title: "B", scans: 2)
        await model.openDocument(id: a)
        #expect(model.scans.count == 1)
        await model.deleteDocument(id: a)
        #expect(model.openedDocument == nil)
        #expect(model.scans.count == 3, "Wieder die letzten Scans des Archivs, auch die der gelöschten Serie")
        await model.disconnect()
    }

    @Test func deletingAnUnknownSeriesChangesNothing() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        _ = try await record(model, title: "Bleibt", scans: 1)
        let logged = model.log.count
        await model.deleteDocument(id: UUID())
        #expect(model.savedDocuments.count == 1 && model.log.count == logged)
        await model.disconnect()
    }

    // MARK: Blättern

    @Test func openingShowsOnlyTheScansOfThatSeriesNewestFirst() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let a = try await record(model, title: "A", scans: 2)
        let b = try await record(model, title: "B", scans: 3)
        await model.openDocument(id: a)
        let docA = try #require(model.savedDocuments.first { $0.id == a })
        #expect(model.openedDocument?.id == a && model.scans.count == 2)
        #expect(model.scans.map(\.id) == docA.pages.map(\.scanID).reversed(), "Neueste zuerst")
        await model.openDocument(id: b)
        #expect(model.openedDocument?.id == b && model.scans.count == 3, "Von einer Serie zur nächsten")
        #expect(model.selectedID == model.scans.first?.id)
        await model.disconnect()
    }

    @Test func aBookKeepsItsPageControlsAfterTheSeriesEnded() async throws {
        // Früher verschwanden Seiten und Regler einer Doppelseite mit „Serie beenden“.
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let id = try await record(model, title: "Buch", scans: 1, book: true)
        let scanID = try #require(model.scans.first?.id)
        #expect(model.series == nil && model.openedDocument?.id == id)
        #expect(model.isBookScan(scanID))
        #expect(model.pages(of: scanID).count == 2)
        await model.disconnect()
    }

    @Test func pagesOfAnOpenedBookCanBeEditedAndAreSaved() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = makeModel(archive: archive)
        await first.connect()
        let id = try await record(first, title: "Buch", scans: 1, book: true)
        await first.disconnect()

        let model = makeModel(archive: archive)
        await model.loadArchive(); await model.connect()
        await model.openDocument(id: id)
        let scanID = try #require(model.scans.first?.id)
        #expect(model.isBookScan(scanID), "Auch ein nach dem Neustart geöffnetes Buch hat seine Seiten")
        #expect(await eventually { model.pages(of: scanID).allSatisfy { model.pagePreviews[$0.id] != nil } }, "Seitenansichten fehlen")
        let left = try #require(model.pages(of: scanID).first)
        model.setPageRotation(pageID: left.id, degrees: 3)
        #expect(model.pages(of: scanID).first?.corrections.rotation.degrees == 3)
        let saved = try ArchiveStore(root: archive).loadDocument(id: id)
        #expect(saved.pages.first?.corrections.rotation.degrees == 3, "Die Änderung steht auf der Platte")
        await model.disconnect()
    }

    @Test func openingIsNotPossibleWhileASeriesRuns() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let old = try await record(model, title: "Alt", scans: 1)
        model.startSeries(title: "Läuft")
        await model.openDocument(id: old)
        #expect(model.openedDocument == nil && model.series?.title == "Läuft")
        await model.disconnect()
    }

    @Test func closingShowsTheLatestScansAgain() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let a = try await record(model, title: "A", scans: 1)
        _ = try await record(model, title: "B", scans: 2)
        await model.openDocument(id: a)
        #expect(model.scans.count == 1)
        await model.closeDocument()
        #expect(model.openedDocument == nil && model.scans.count == 3)
        await model.disconnect()
    }

    @Test func startingANewSeriesWhileBrowsingEmptiesTheStrip() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let a = try await record(model, title: "A", scans: 2)
        await model.openDocument(id: a)
        model.startSeries(title: "Neu")
        #expect(model.openedDocument == nil && model.scans.isEmpty, "Die neue Serie beginnt leer")
        await model.scan()
        #expect(model.scans.count == 1)
        await model.disconnect()
    }

    @Test func missingOriginalsAreSkippedWhenShowingASeries() async throws {
        let (dir, archive) = tempArchive(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: archive)
        await model.connect()
        let id = try await record(model, title: "Lücke", scans: 2)
        // Die Analysen müssen durch sein: Eine, die nach dem Überschreiben unten noch fertig wird, schriebe das Dokument zurück.
        for _ in 0..<400 where !model.analyzing.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(model.analyzing.isEmpty)
        // Ein Dokument verweist auf einen Scan, den es nicht gibt (etwa von Hand aus dem Archiv genommen).
        var doc = try #require(model.savedDocuments.first { $0.id == id })
        doc.append(DocumentPage(scanID: UUID()))
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let documents = archive.appendingPathComponent("documents/\(id.uuidString.lowercased()).json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(doc).write(to: documents)
        await model.disconnect()

        let again = makeModel(archive: archive)
        await again.loadArchive()
        await again.openDocument(id: id)
        #expect(again.openedDocument?.id == id, "Die Serie mit dem fehlenden Scan ließ sich nicht öffnen")
        #expect(again.openedDocument?.pages.count == 3)
        #expect(again.scans.count == 2, "Der fehlende Scan wird übersprungen, die Serie bleibt ansehbar")
        await again.disconnect()
    }
}
