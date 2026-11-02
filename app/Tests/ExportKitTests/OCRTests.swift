import Testing
import Foundation
import CoreGraphics
import PDFKit
import ScannerKit
import ImagingKit
import ArchiveKit
@testable import ExportKit

/// Erkenner für Tests: liefert feste Zeilen und merkt sich die Aufrufe.
private final class FakeRecognizer: TextRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _languages: [[String]] = []
    let lines: [RecognizedLine]
    let failOnCall: Int?

    init(lines: [RecognizedLine], failOnCall: Int? = nil) {
        self.lines = lines
        self.failOnCall = failOnCall
    }

    var calls: Int { lock.withLock { _calls } }
    var languages: [[String]] { lock.withLock { _languages } }

    struct Failure: Error {}

    func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let call = lock.withLock { () -> Int in _calls += 1; _languages.append(languages); return _calls }
        if call == failOnCall { throw Failure() }
        return lines
    }
}

@Suite("Texterkennung im PDF")
struct OCRTests {
    private struct Fixture {
        let store: ArchiveStore
        let dir: URL
        func pdf(_ name: String = "out.pdf") -> URL { dir.appendingPathComponent(name) }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeFixture() -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-ocr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Fixture(store: ArchiveStore(root: dir.appendingPathComponent("archiv")), dir: dir)
    }

    private func store(_ image: CGImage, in store: ArchiveStore) async throws -> ScanRecord {
        let session = try await SyntheticPage.scanner(delivering: image).openSession(
            format: ScanFormat(width: image.width, height: image.height), settings: .archival)
        let capture = try await session.capture()
        await session.close()
        return try store.store(capture)
    }

    private func document(_ scan: ScanRecord, pages: Int = 1) -> ScanDocument {
        var doc = ScanDocument(title: "OCR")
        for _ in 0..<pages { doc.append(DocumentPage(scanID: scan.id)) }
        return doc
    }

    private let line = RecognizedLine(text: "Schützenfest in Mulsum", box: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.06))

    @Test func textLayerMakesThePDFSearchableWithUmlauts() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await store(SyntheticPage.textPage(width: 800, height: 1000), in: f.store)
        let exporter = PDFExporter(store: f.store, recognizer: FakeRecognizer(lines: [line]))
        let report = try exporter.export(document(scan), to: f.pdf(), options: ExportOptions(dpi: 72, ocr: true))
        #expect(report == ExportReport(pageCount: 1, ocrFailures: [], recognizedLines: 1))
        let text = PDFDocument(url: f.pdf())?.page(at: 0)?.string ?? ""
        #expect(text.contains("Schützenfest in Mulsum"))
        #expect(PDFDocument(url: f.pdf())?.findString("Mulsum", withOptions: []).isEmpty == false)
    }

    @Test func textSitsWhereTheLineIs() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await store(SyntheticPage.textPage(width: 800, height: 1000), in: f.store)
        try PDFExporter(store: f.store, recognizer: FakeRecognizer(lines: [line]))
            .export(document(scan), to: f.pdf(), options: ExportOptions(dpi: 72, ocr: true))
        let page = try #require(PDFDocument(url: f.pdf())?.page(at: 0))
        let size = page.bounds(for: .mediaBox).size
        // Der Rahmen der Zeile, in PDF-Punkten.
        let inside = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                            width: line.box.width * size.width, height: line.box.height * size.height)
        #expect(page.selection(for: inside)?.string?.contains("Mulsum") == true)
        // Ein Rechteck weit davon entfernt trifft nichts.
        let away = CGRect(x: 0.1 * size.width, y: 0.05 * size.height, width: 0.5 * size.width, height: 0.05 * size.height)
        #expect((page.selection(for: away)?.string ?? "").isEmpty)
    }

    @Test func textLayerIsInvisible() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await store(SyntheticPage.textPage(width: 400, height: 500), in: f.store)
        let doc = document(scan)
        let recognizer = FakeRecognizer(lines: [line])
        try PDFExporter(store: f.store, recognizer: recognizer).export(doc, to: f.pdf("mit.pdf"), options: ExportOptions(dpi: 72, ocr: true))
        try PDFExporter(store: f.store, recognizer: recognizer).export(doc, to: f.pdf("ohne.pdf"), options: ExportOptions(dpi: 72, ocr: false))

        func pixels(_ url: URL) throws -> Data {
            let page = try #require(PDFDocument(url: url)?.page(at: 0))
            let image = page.thumbnail(of: CGSize(width: 400, height: 500), for: .mediaBox)
            return try #require(image.tiffRepresentation)
        }
        #expect(try pixels(f.pdf("mit.pdf")) == pixels(f.pdf("ohne.pdf")))
    }

    @Test func ocrOffNeverCallsTheRecognizer() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await store(SyntheticPage.textPage(width: 400, height: 500), in: f.store)
        let recognizer = FakeRecognizer(lines: [line])
        try PDFExporter(store: f.store, recognizer: recognizer).export(document(scan, pages: 2), to: f.pdf())
        #expect(recognizer.calls == 0)
        #expect((PDFDocument(url: f.pdf())?.page(at: 0)?.string ?? "").isEmpty)
    }

    @Test func languagesArePassedOn() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await store(SyntheticPage.textPage(width: 400, height: 500), in: f.store)
        let recognizer = FakeRecognizer(lines: [])
        try PDFExporter(store: f.store, recognizer: recognizer)
            .export(document(scan), to: f.pdf(), options: ExportOptions(ocr: true, ocrLanguages: ["de-DE", "en-US"]))
        #expect(recognizer.languages == [["de-DE", "en-US"]])
    }

    @Test func aFailedPageKeepsThePDFAndIsReported() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await store(SyntheticPage.textPage(width: 400, height: 500), in: f.store)
        let recognizer = FakeRecognizer(lines: [line], failOnCall: 2)
        let report = try PDFExporter(store: f.store, recognizer: recognizer)
            .export(document(scan, pages: 3), to: f.pdf(), options: ExportOptions(dpi: 72, ocr: true))
        #expect(report.ocrFailures == [2])
        #expect(report.recognizedLines == 2)
        let pdf = try #require(PDFDocument(url: f.pdf()))
        #expect(pdf.pageCount == 3)
        #expect(pdf.page(at: 0)?.string?.contains("Mulsum") == true)
        #expect((pdf.page(at: 1)?.string ?? "").isEmpty)           // ohne Text, aber da
        #expect(pdf.page(at: 2)?.string?.contains("Mulsum") == true)
    }

    @Test func degenerateBoxesAreSkipped() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await store(SyntheticPage.textPage(width: 400, height: 500), in: f.store)
        let broken = [RecognizedLine(text: "leer", box: .zero),
                      RecognizedLine(text: "", box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05)),
                      line]
        try PDFExporter(store: f.store, recognizer: FakeRecognizer(lines: broken))
            .export(document(scan), to: f.pdf(), options: ExportOptions(dpi: 72, ocr: true))
        let text = PDFDocument(url: f.pdf())?.page(at: 0)?.string ?? ""
        #expect(text.contains("Mulsum"))
        #expect(!text.contains("leer"))
    }

    @Test func visionReadsASyntheticPage() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await store(SyntheticPage.textPage(width: 1600, height: 2000), in: f.store)
        let report = try PDFExporter(store: f.store)
            .export(document(scan), to: f.pdf(), options: ExportOptions(dpi: 150, ocr: true))
        #expect(report.ocrFailures.isEmpty)
        #expect(report.recognizedLines > 10)
        let text = PDFDocument(url: f.pdf())?.page(at: 0)?.string ?? ""
        #expect(text.contains("Heimatverein") || text.contains("Chronik") || text.contains("Mulsum"))
    }
}
