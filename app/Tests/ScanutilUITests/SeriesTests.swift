import ArchiveKit
import ExportKit
import PDFKit
import CoreGraphics
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

@MainActor
@Suite("Serienmodus")
struct SeriesTests {
    nonisolated private static let confident = AnalysisResult(
        corrections: Corrections(rotation: RotationCorrection(degrees: 1.5, enabled: true, source: .automatic, confidence: 0.9)),
        warnings: []
    )

    /// Ohne eigene Vorschaubilder des Mocks: der Trigger bekommt nur die Signaturen, die der Test einspeist.
    /// Feste Doppelseitenanalyse: links 1°, rechts −1°, nach einer kurzen Wartezeit wie bei der echten Analyse.
    nonisolated private static let book: @Sendable (CGImage) -> BookAnalysisResult = { _ in
        Thread.sleep(forTimeInterval: 0.15)
        func corrections(_ degrees: Double) -> Corrections {
            Corrections(crop: CropCorrection(quad: .full, enabled: true, source: .automatic, confidence: 0.9),
                        rotation: RotationCorrection(degrees: degrees, enabled: true, source: .automatic, confidence: 0.9))
        }
        return BookAnalysisResult(left: corrections(1), right: corrections(-1), warnings: ["Der Falz ist unsicher."])
    }

    /// Texterkennung für Tests: liefert eine Zeile oder scheitert.
    private struct StubRecognizer: TextRecognizer {
        let fail: Bool
        struct Failure: Error {}
        func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
            if fail { throw Failure() }
            return [RecognizedLine(text: "Heimatverein", box: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.05))]
        }
    }

    private func makeModel(recognizer: any TextRecognizer = StubRecognizer(fail: false)) async -> (AppModel, ArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-series-\(UUID().uuidString)")
        let store = ArchiveStore(root: dir)
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: store, thumbnailSize: 64,
                             analyze: { _ in SeriesTests.confident }, analyzeBook: SeriesTests.book, recognizer: recognizer)
        await model.connect()
        return (model, store, dir)
    }

    private func page(row: Int?) -> FrameSignature {
        var cells = [UInt8](repeating: 230, count: FrameSignature.width * FrameSignature.height)
        if let row { for x in 4..<40 { cells[row * FrameSignature.width + x] = 40 } }
        return FrameSignature(cells: cells)!
    }

    private let hand: FrameSignature = {
        var cells = [UInt8](repeating: 230, count: FrameSignature.width * FrameSignature.height)
        for i in 0..<(cells.count / 3) { cells[i] = 60 }
        return FrameSignature(cells: cells)!
    }()

    /// Zehn Bilder pro Sekunde, `seconds` lang.
    private func feed(_ model: AppModel, _ frame: FrameSignature, from start: Double, seconds: Double) async {
        var t = start
        while t < start + seconds - 1e-9 { await model.processSeriesFrame(frame, at: t); t += 0.1 }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func startSavesAnEmptyDocument() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Chronik")
        let id = try #require(model.series?.id)
        #expect(model.isSeriesActive)
        #expect(try store.loadDocument(id: id).pages.isEmpty)
        model.endSeries()
        #expect(!model.isSeriesActive)
        #expect(try store.loadDocument(id: id).title == "Chronik")   // bleibt gespeichert
        await model.disconnect()
    }

    @Test func cannotStartWithoutConnection() {
        let model = AppModel(scanner: MockScanner(previewsEnabled: false),
                             store: ArchiveStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID())")))
        model.startSeries(title: "T")
        #expect(!model.isSeriesActive)
    }

    @Test func calmAfterMotionCapturesAndAppendsPage() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Auto")
        await feed(model, page(row: 5), from: 0, seconds: 2)
        #expect(model.scans.count == 1)
        let doc = try store.loadDocument(id: try #require(model.series?.id))
        #expect(doc.pages.map(\.scanID) == [model.scans[0].id])
        await model.disconnect()
    }

    @Test func pageTurnsBuildTheDocumentInOrder() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch")
        await feed(model, page(row: 5), from: 0, seconds: 2)
        await feed(model, hand, from: 2, seconds: 0.6)
        await feed(model, page(row: 20), from: 2.6, seconds: 2)
        await feed(model, hand, from: 4.6, seconds: 0.6)
        await feed(model, page(row: 12), from: 5.2, seconds: 2)
        #expect(model.scans.count == 3)
        let doc = try store.loadDocument(id: try #require(model.series?.id))
        // scans ist neueste zuerst, das Dokument älteste zuerst.
        #expect(doc.pages.map(\.scanID) == model.scans.reversed().map(\.id))
        await model.disconnect()
    }

    @Test func unchangedPageIsNotCapturedTwice() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Dublette")
        await feed(model, page(row: 5), from: 0, seconds: 2)
        await feed(model, hand, from: 2, seconds: 0.6)
        await feed(model, page(row: 5), from: 2.6, seconds: 2)
        #expect(model.scans.count == 1)
        #expect(model.message?.contains("unverändert") == true)
        await model.disconnect()
    }

    @Test func manualOnlyModeStillFillsDocument() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Hand")
        model.autoTriggerEnabled = false
        await feed(model, page(row: 5), from: 0, seconds: 3)
        #expect(model.scans.isEmpty)
        await model.scan()
        #expect(model.scans.count == 1)
        #expect(try store.loadDocument(id: try #require(model.series?.id)).pages.count == 1)
        await model.disconnect()
    }

    @Test func manualScanBlocksAutoShotOfSamePage() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Hand und Auto")
        await model.processSeriesFrame(page(row: 5), at: 0)
        await model.scan()
        await feed(model, page(row: 5), from: 0.1, seconds: 3)
        #expect(model.scans.count == 1)
        await model.disconnect()
    }

    @Test func noPagesWithoutSeries() async {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await feed(model, page(row: 5), from: 0, seconds: 3)
        #expect(model.scans.isEmpty)
        await model.scan()
        #expect(model.scans.count == 1)
        #expect(model.series == nil)
        await model.disconnect()
    }

    @Test func correctionsAreMirroredIntoThePage() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Korrekturen")
        await model.scan()
        let scanID = try #require(model.scans.first?.id)
        // Die Analyse läuft im Hintergrund; danach trägt die Seite dieselbe Drehung wie der Scan.
        #expect(await eventually { model.series?.pages.first?.corrections.rotation.degrees == 1.5 })
        model.setRotation(id: scanID, degrees: -0.5)
        let doc = try store.loadDocument(id: try #require(model.series?.id))
        #expect(doc.pages.first?.corrections.rotation.degrees == -0.5)
        #expect(doc.pages.first?.corrections.rotation.source == .manual)
        await model.disconnect()
    }

    @Test func exportsTheSeriesAsPDF() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Export")
        await model.scan(); await model.scan()
        let target = dir.appendingPathComponent("serie.pdf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await model.exportSeries(to: target, options: ExportOptions(dpi: 72))
        #expect(model.message == nil)
        #expect(model.exportProgress == nil)
        #expect(model.lastExportURL == target)
        #expect(PDFDocument(url: target)?.pageCount == 2)
        await model.disconnect()
    }

    @Test func exportWithoutPagesSaysSo() async {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Leer")
        let target = dir.appendingPathComponent("leer.pdf")
        await model.exportSeries(to: target)
        #expect(model.message?.contains("keine Seiten") == true)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        await model.disconnect()
    }

    @Test func exportFailureShowsMessageAndClearsProgress() async {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Fehler")
        await model.scan()
        let unwritable = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.pdf")
        await model.exportSeries(to: unwritable)
        #expect(model.message?.contains("fehlgeschlagen") == true)
        #expect(model.exportProgress == nil)
        #expect(model.lastExportURL == nil)
        await model.disconnect()
    }

    // MARK: Buchmodus

    @Test func bookSeriesAddsALeftAndARightPagePerScan() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let scanID = try #require(model.scans.first?.id)
        #expect(model.seriesIsBook)
        #expect(model.isBookScan(scanID))
        let doc = try store.loadDocument(id: try #require(model.series?.id))
        #expect(doc.pages.map(\.region) == [.left, .right])
        #expect(doc.pages.allSatisfy { $0.scanID == scanID })
        #expect(model.pages(of: scanID).count == 2)
        await model.disconnect()
    }

    @Test func singlePageSeriesIsNotABookSeries() async {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Blätter")
        await model.scan()
        #expect(!model.seriesIsBook)
        #expect(model.scans.first.map { !model.isBookScan($0.id) } == true)
        #expect(model.series?.pages.map(\.region) == [.whole])
        await model.disconnect()
    }

    @Test func bookAnalysisGivesEachPageItsOwnCorrectionsAndPreview() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let scanID = try #require(model.scans.first?.id)
        #expect(await eventually { model.pages(of: scanID).first?.corrections.rotation.degrees == 1 })
        let pages = model.pages(of: scanID)
        #expect(pages.map(\.corrections.rotation.degrees) == [1, -1])
        #expect(await eventually { pages.allSatisfy { model.pagePreviews[$0.id] != nil } })
        #expect(model.scans.first?.warnings == ["Der Falz ist unsicher."])
        let saved = try store.loadDocument(id: try #require(model.series?.id))
        #expect(saved.pages.map(\.corrections.rotation.degrees) == [1, -1])
        await model.disconnect()
    }

    @Test func manualChangeBeforeAnalysisFinishesIsKept() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let scanID = try #require(model.scans.first?.id)
        let left = try #require(model.pages(of: scanID).first)
        model.setPageRotation(pageID: left.id, degrees: 4)          // die Analyse läuft noch
        // Die Automatik kommt für die andere Seite an; erst dann ist die Analyse sicher durch.
        #expect(await eventually { model.pages(of: scanID).last?.corrections.rotation.degrees == -1 })
        let pages = model.pages(of: scanID)
        #expect(pages[0].corrections.rotation.degrees == 4)         // Handeingabe gilt
        #expect(pages[0].corrections.rotation.source == .manual)
        #expect(pages[1].corrections.rotation.degrees == -1)        // die andere Seite bekommt die Automatik
        await model.disconnect()
    }

    @Test func reanalyzeDiscardsManualPageChanges() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let scanID = try #require(model.scans.first?.id)
        #expect(await eventually { model.analyzing.isEmpty && model.pages(of: scanID).first?.corrections.rotation.degrees == 1 })
        model.setPageRotation(pageID: model.pages(of: scanID)[0].id, degrees: 4)
        await model.reanalyze(id: scanID)
        #expect(model.pages(of: scanID)[0].corrections.rotation.degrees == 1)
        await model.disconnect()
    }

    @Test func editingTheSpreadItemDoesNotTouchTheBookPages() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let scanID = try #require(model.scans.first?.id)
        #expect(await eventually { model.analyzing.isEmpty && model.pages(of: scanID).first?.corrections.rotation.degrees == 1 })
        let before = model.pages(of: scanID).map(\.corrections)
        model.setRotation(id: scanID, degrees: 9)
        #expect(model.pages(of: scanID).map(\.corrections) == before)
        await model.disconnect()
    }

    @Test func bookSeriesExportsTwoPdfPagesPerScan() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan(); await model.scan()
        let target = dir.appendingPathComponent("buch.pdf")
        await model.exportSeries(to: target, options: ExportOptions(dpi: 72))
        #expect(model.message == nil)
        #expect(PDFDocument(url: target)?.pageCount == 4)
        await model.disconnect()
    }

    @Test func endingTheSeriesEndsBookMode() async {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        model.endSeries()
        #expect(!model.seriesIsBook)
    }

    // MARK: Texterkennung

    @Test func exportWithOCRReportsRecognizedLines() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "OCR")
        await model.scan(); await model.scan()
        var options = ExportOptions(dpi: 72); options.ocr = true
        let target = dir.appendingPathComponent("ocr.pdf")
        await model.exportSeries(to: target, options: options)
        #expect(model.message == nil)
        #expect(model.lastExportReport == ExportReport(pageCount: 2, ocrFailures: [], recognizedLines: 2))
        #expect(PDFDocument(url: target)?.page(at: 1)?.string?.contains("Heimatverein") == true)
        await model.disconnect()
    }

    @Test func failedOCRKeepsThePDFAndSaysSo() async throws {
        let (model, _, dir) = await makeModel(recognizer: StubRecognizer(fail: true)); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "OCR")
        await model.scan()
        var options = ExportOptions(dpi: 72); options.ocr = true
        let target = dir.appendingPathComponent("ocr.pdf")
        await model.exportSeries(to: target, options: options)
        #expect(model.lastExportURL == target)
        #expect(PDFDocument(url: target)?.pageCount == 1)
        #expect(model.message?.contains("Texterkennung schlug bei 1 Seite") == true)
        await model.disconnect()
    }
}
