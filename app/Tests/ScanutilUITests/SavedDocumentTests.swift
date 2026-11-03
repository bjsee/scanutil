import ArchiveKit
import CoreGraphics
import ExportKit
import Foundation
import ImagingKit
import PDFKit
import ScannerKit
import Testing
@testable import ScanutilUI

/// Ein Buch aufnehmen, die Serie beenden, die App schließen: das Dokument muss sich trotzdem als PDF ausgeben lassen.
@MainActor
@Suite("Gespeicherte Dokumente")
struct SavedDocumentTests {
    nonisolated private static let none: @Sendable (CGImage) -> AnalysisResult = { _ in AnalysisResult(corrections: Corrections(), warnings: []) }

    private func makeModel(archive: URL, scanner: MockScanner = MockScanner(previewsEnabled: false)) -> AppModel {
        AppModel(scanner: scanner, store: ArchiveStore(root: archive), thumbnailSize: 64, analyze: Self.none,
                 sound: SilentSound(), defaults: nil)
    }

    private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-docs-\(UUID().uuidString)") }

    private func pdfURL(_ dir: URL) -> URL { dir.appendingPathComponent("out.pdf") }

    /// Nimmt eine Serie mit `scans` Aufnahmen auf und beendet sie.
    private func recordSeries(_ model: AppModel, title: String, scans: Int, book: Bool = false) async -> UUID? {
        await model.connect()
        model.startSeries(title: title, book: book)
        let id = model.series?.id
        for _ in 0..<scans { await model.scan() }
        model.endSeries()
        return id
    }

    @Test func anEndedSeriesStaysInTheListAndCanBeExported() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: dir.appendingPathComponent("archiv"))
        let id = try #require(await recordSeries(model, title: "Sagenbuch", scans: 3))
        #expect(model.series == nil, "Die Serie ist beendet")
        let saved = try #require(model.savedDocuments.first)
        #expect(saved.id == id && saved.title == "Sagenbuch" && saved.pages.count == 3)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await model.exportDocument(saved, to: pdfURL(dir), options: ExportOptions(dpi: 72))
        #expect(model.message == nil)
        #expect(PDFDocument(url: pdfURL(dir))?.pageCount == 3)
        await model.disconnect()
    }

    @Test func aBookCanBeExportedAfterTheAppWasRestartedAndWithoutAScanner() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("archiv")
        let first = makeModel(archive: archive)
        let id = try #require(await recordSeries(first, title: "Sagenbuch", scans: 2, book: true))
        await first.disconnect()

        // Neuer Start, der Scanner ist aus: das Archiv wird trotzdem geladen.
        let scanner = MockScanner(startsSwitchedOff: true)
        let second = makeModel(archive: archive, scanner: scanner)
        await second.loadArchive()
        await second.connect()
        #expect(second.status != .ready)
        let saved = try #require(second.savedDocuments.first)
        #expect(saved.id == id)
        #expect(saved.pages.count == 4, "Zwei Doppelseiten ergeben vier Seiten")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await second.exportDocument(saved, to: pdfURL(dir), options: ExportOptions(dpi: 72))
        #expect(second.message == nil, "Der Export ohne Scanner schlug fehl: \(second.message ?? "")")
        #expect(PDFDocument(url: pdfURL(dir))?.pageCount == 4)
        await second.disconnect()
    }

    @Test func theCorrectionsSavedWithTheDocumentGoIntoThePDF() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("archiv")
        let model = makeModel(archive: archive)
        await model.connect()
        model.startSeries(title: "Korrektur")
        await model.scan(); await model.scan()
        let rotated = try #require(model.series?.pages.first)
        model.setPageRotation(pageID: rotated.id, degrees: 10)   // beschneidet die erste Seite auf das größte Rechteck ohne leere Ecken
        model.endSeries()
        await model.disconnect()

        let again = makeModel(archive: archive)
        await again.loadArchive()
        let saved = try #require(again.savedDocuments.first)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await again.exportDocument(saved, to: pdfURL(dir), options: ExportOptions(dpi: 72))
        let pdf = try #require(PDFDocument(url: pdfURL(dir)))
        let first = try #require(pdf.page(at: 0)?.bounds(for: .mediaBox).size)
        let second = try #require(pdf.page(at: 1)?.bounds(for: .mediaBox).size)
        #expect(first.width < second.width && first.height < second.height, "Die gedrehte erste Seite muss kleiner sein: \(first) gegen \(second)")
        await again.disconnect()
    }

    @Test func theListIsNewestFirstAndFollowsTheRunningSeries() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: dir.appendingPathComponent("archiv"))
        _ = await recordSeries(model, title: "Alt", scans: 1)
        try await Task.sleep(for: .milliseconds(20))
        await model.connect()
        model.startSeries(title: "Neu")
        #expect(model.savedDocuments.map(\.title) == ["Neu", "Alt"])
        #expect(model.savedDocuments.first?.pages.count == 0)
        await model.scan()
        #expect(model.savedDocuments.first?.pages.count == 1, "Die Liste folgt der laufenden Serie")
        #expect(model.savedDocuments.count == 2)
        await model.disconnect()
    }

    @Test func loadingTheArchiveTwiceDoesNotDuplicate() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("archiv")
        let first = makeModel(archive: archive)
        _ = await recordSeries(first, title: "Eins", scans: 1)
        await first.disconnect()
        let model = makeModel(archive: archive)
        await model.loadArchive()
        await model.loadArchive()
        await model.connect()
        #expect(model.savedDocuments.count == 1)
        #expect(model.scans.count == 1)
        await model.disconnect()
    }

    @Test func anEmptyDocumentGivesAWarningAndNoFile() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: dir.appendingPathComponent("archiv"))
        await model.connect()
        model.startSeries(title: "Leer")
        model.endSeries()
        let empty = try #require(model.savedDocuments.first)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await model.exportDocument(empty, to: pdfURL(dir))
        #expect(model.message?.contains("keine Seiten") == true)
        #expect(!FileManager.default.fileExists(atPath: pdfURL(dir).path))
        await model.disconnect()
    }

    @Test func exportingASavedDocumentWhileASeriesRunsExportsThatDocument() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archive: dir.appendingPathComponent("archiv"))
        _ = await recordSeries(model, title: "Altes Buch", scans: 2)
        let old = try #require(model.savedDocuments.first)
        model.startSeries(title: "Neues Buch")
        await model.scan()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await model.exportDocument(old, to: pdfURL(dir), options: ExportOptions(dpi: 72))
        #expect(PDFDocument(url: pdfURL(dir))?.pageCount == 2, "Es muss das alte Dokument sein, nicht die laufende Serie")
        await model.disconnect()
    }
}
