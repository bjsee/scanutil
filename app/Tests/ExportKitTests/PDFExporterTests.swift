import Testing
import Foundation
import PDFKit
import ScannerKit
import ImagingKit
import ArchiveKit
@testable import ExportKit

@Suite("PDF-Export")
struct PDFExporterTests {
    private struct Fixture {
        let store: ArchiveStore
        let dir: URL
        var pdf: URL { dir.appendingPathComponent("out.pdf") }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeFixture() -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-export-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Fixture(store: ArchiveStore(root: dir.appendingPathComponent("archiv")), dir: dir)
    }

    private func storeScan(_ store: ArchiveStore, width: Int = 320, height: Int = 240) async throws -> ScanRecord {
        let format = ScanFormat(width: width, height: height)
        let session = try await MockScanner(formats: [format]).openSession(format: format, settings: .archival)
        let capture = try await session.capture()
        await session.close()
        return try store.store(capture)
    }

    private func pageSizes(_ url: URL) -> [CGSize] {
        guard let pdf = PDFDocument(url: url) else { return [] }
        return (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.bounds(for: .mediaBox).size }
    }

    @Test func exportsOnePagePerDocumentPageInOrder() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let wide = try await storeScan(f.store, width: 320, height: 240)
        let tall = try await storeScan(f.store, width: 200, height: 300)
        var doc = ScanDocument(title: "Reihenfolge")
        doc.append(DocumentPage(scanID: wide.id)); doc.append(DocumentPage(scanID: tall.id))

        try PDFExporter(store: f.store).export(doc, to: f.pdf, options: ExportOptions(dpi: 72))
        let sizes = pageSizes(f.pdf)
        #expect(sizes.count == 2)
        #expect(sizes.first == CGSize(width: 320, height: 240))
        #expect(sizes.last == CGSize(width: 200, height: 300))
    }

    @Test func pageSizeFollowsDpi() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await storeScan(f.store)
        var doc = ScanDocument(title: "dpi"); doc.append(DocumentPage(scanID: scan.id))
        try PDFExporter(store: f.store).export(doc, to: f.pdf, options: ExportOptions(dpi: 144))
        #expect(pageSizes(f.pdf) == [CGSize(width: 160, height: 120)])
    }

    @Test func downscalingKeepsPageSize() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await storeScan(f.store)
        var doc = ScanDocument(title: "web"); doc.append(DocumentPage(scanID: scan.id))
        let exporter = PDFExporter(store: f.store)

        let full = f.dir.appendingPathComponent("voll.pdf"), small = f.dir.appendingPathComponent("klein.pdf")
        try exporter.export(doc, to: full, options: ExportOptions(dpi: 72, maxLongSide: nil))
        try exporter.export(doc, to: small, options: ExportOptions(dpi: 72, maxLongSide: 80))
        #expect(pageSizes(small) == pageSizes(full))
        let bytes = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0 }
        #expect(bytes(small) < bytes(full))
    }

    @Test func leftAndRightPagesAreHalvesOfOneScan() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await storeScan(f.store, width: 400, height: 200)
        var doc = ScanDocument(title: "Buch")
        doc.append(DocumentPage(scanID: scan.id, region: .left))
        doc.append(DocumentPage(scanID: scan.id, region: .right))
        try PDFExporter(store: f.store).export(doc, to: f.pdf, options: ExportOptions(dpi: 72))
        let sizes = pageSizes(f.pdf)
        #expect(sizes.count == 2)
        for size in sizes {
            #expect(abs(size.width - 200) <= 2)
            #expect(abs(size.height - 200) <= 2)
        }
    }

    @Test func writesMetadata() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await storeScan(f.store)
        var doc = ScanDocument(title: "Chronik 1524", metadata: .init(author: "N. N.", signature: "MUL-12", keywords: ["Mulsum", "Chronik"]))
        doc.append(DocumentPage(scanID: scan.id))
        try PDFExporter(store: f.store).export(doc, to: f.pdf)
        let attributes = PDFDocument(url: f.pdf)?.documentAttributes
        #expect(attributes?[PDFDocumentAttribute.titleAttribute] as? String == "Chronik 1524")
        #expect(attributes?[PDFDocumentAttribute.authorAttribute] as? String == "N. N.")
        #expect(attributes?[PDFDocumentAttribute.subjectAttribute] as? String == "MUL-12")
    }

    @Test func reportsProgressPerPage() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await storeScan(f.store)
        var doc = ScanDocument(title: "p")
        for _ in 0..<3 { doc.append(DocumentPage(scanID: scan.id)) }
        nonisolated(unsafe) var steps: [[Int]] = []
        try PDFExporter(store: f.store).export(doc, to: f.pdf) { steps.append([$0, $1]) }
        #expect(steps == [[1, 3], [2, 3], [3, 3]])
    }

    @Test func emptyDocumentIsRejectedWithoutFile() throws {
        let f = makeFixture(); defer { f.cleanup() }
        #expect(throws: ExportError.emptyDocument) { try PDFExporter(store: f.store).export(ScanDocument(title: "leer"), to: f.pdf) }
        #expect(!FileManager.default.fileExists(atPath: f.pdf.path))
    }

    @Test func failureLeavesNoFileAndKeepsExistingOne() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await storeScan(f.store)
        var good = ScanDocument(title: "ok"); good.append(DocumentPage(scanID: scan.id))
        let exporter = PDFExporter(store: f.store)
        try exporter.export(good, to: f.pdf)
        let before = try Data(contentsOf: f.pdf)

        var bad = good
        bad.append(DocumentPage(scanID: UUID()))   // Original fehlt
        #expect(throws: ArchiveError.self) { try exporter.export(bad, to: f.pdf) }
        #expect(try Data(contentsOf: f.pdf) == before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func exportReplacesExistingPDF() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await storeScan(f.store)
        var doc = ScanDocument(title: "v1"); doc.append(DocumentPage(scanID: scan.id))
        let exporter = PDFExporter(store: f.store)
        try exporter.export(doc, to: f.pdf)
        doc.append(DocumentPage(scanID: scan.id))
        try exporter.export(doc, to: f.pdf)
        #expect(PDFDocument(url: f.pdf)?.pageCount == 2)
    }

    @Test func cancellationStopsExportAndLeavesNothing() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await storeScan(f.store)
        var doc = ScanDocument(title: "c")
        for _ in 0..<5 { doc.append(DocumentPage(scanID: scan.id)) }
        let exporter = PDFExporter(store: f.store), target = f.pdf
        let task = Task {
            try exporter.export(doc, to: target) { done, _ in if done == 1 { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: f.pdf.path))
    }

    @Test func originalsStayUntouched() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await storeScan(f.store)
        var doc = ScanDocument(title: "o")
        var page = DocumentPage(scanID: scan.id)
        page.corrections.setRotation(degrees: 3)
        doc.append(page)
        try PDFExporter(store: f.store).export(doc, to: f.pdf)
        #expect(try f.store.verify(scan))
    }

    @Test func anUnsureProposalReachesThePDFAsAPageOfTheRightSize() async throws {
        let f = makeFixture(); defer { f.cleanup() }
        let scan = try await storeScan(f.store, width: 400, height: 200)
        var doc = ScanDocument(title: "Unsicher")
        var left = DocumentPage(scanID: scan.id, region: .left), right = DocumentPage(scanID: scan.id, region: .right)
        // Die Seiten liegen im Bild bei x 0,1–0,5 und 0,5–0,9 (mit Rand): der Vorschlag ist schmaler als die Bildhälfte.
        left.corrections.crop = CropCorrection(quad: Quad(topLeft: .init(x: 0.1, y: 0.1), topRight: .init(x: 0.5, y: 0.1),
                                                          bottomRight: .init(x: 0.5, y: 0.9), bottomLeft: .init(x: 0.1, y: 0.9)),
                                               enabled: false, source: .automatic, confidence: 0.4)
        right.corrections.crop = CropCorrection(quad: Quad(topLeft: .init(x: 0.5, y: 0.1), topRight: .init(x: 0.9, y: 0.1),
                                                           bottomRight: .init(x: 0.9, y: 0.9), bottomLeft: .init(x: 0.5, y: 0.9)),
                                                enabled: false, source: .automatic, confidence: 0.4)
        doc.append(left); doc.append(right)
        try PDFExporter(store: f.store).export(doc, to: f.pdf, options: ExportOptions(dpi: 72))
        let sizes = pageSizes(f.pdf)
        #expect(sizes.count == 2)
        // Vorschlag: 160 × 160 Punkte. Die Bildhälfte wäre 200 × 200.
        for size in sizes { #expect(abs(size.width - 160) <= 3 && abs(size.height - 160) <= 3, "Seitengröße \(size)") }
    }
}

@Suite("Seitengeometrie")
struct PageGeometryTests {
    @Test func wholeKeepsCorrections() {
        var page = DocumentPage(scanID: UUID())
        page.corrections.setRotation(degrees: 1)
        #expect(PageGeometry.effectiveCorrections(for: page) == page.corrections)
    }

    @Test func halvesCoverLeftAndRight() {
        let left = PageGeometry.half(of: .full, region: .left)
        let right = PageGeometry.half(of: .full, region: .right)
        #expect(left.topRight == NormalizedPoint(x: 0.5, y: 0))
        #expect(right.topLeft == NormalizedPoint(x: 0.5, y: 0))
        #expect(left.bottomRight == right.bottomLeft)
    }

    @Test func ownActiveCropWinsOverRegion() {
        var page = DocumentPage(scanID: UUID(), region: .left)
        let own = Quad(topLeft: .init(x: 0.1, y: 0.1), topRight: .init(x: 0.4, y: 0.1),
                       bottomRight: .init(x: 0.4, y: 0.9), bottomLeft: .init(x: 0.1, y: 0.9))
        page.corrections.setCrop(own)
        #expect(PageGeometry.effectiveCorrections(for: page).crop.quad == own)
    }

    @Test func masterSwitchOffStillSplitsButDoesNotRotate() {
        var page = DocumentPage(scanID: UUID(), region: .right)
        page.corrections.setRotation(degrees: 2)
        page.corrections.setEnabled(false)
        let effective = PageGeometry.effectiveCorrections(for: page)
        #expect(effective.crop.enabled)
        #expect(effective.rotation.enabled == false)
    }

    private let proposal = Quad(topLeft: .init(x: 0.14, y: 0.11), topRight: .init(x: 0.46, y: 0.11),
                                bottomRight: .init(x: 0.46, y: 0.72), bottomLeft: .init(x: 0.14, y: 0.72))

    @Test func anUnsureAutomaticProposalIsUsedForABookPageInsteadOfTheImageHalf() {
        // Der Fall aus dem echten Buch: Zuschnitt „aus“ (zu unsicher für die Automatik), Vorschlag vorhanden.
        var page = DocumentPage(scanID: UUID(), region: .left)
        page.corrections.crop = CropCorrection(quad: proposal, enabled: false, source: .automatic, confidence: 0.39)
        let effective = PageGeometry.effectiveCorrections(for: page)
        #expect(effective.crop.quad == proposal, "Der Vorschlag, nicht die Hälfte des ganzen Bildes")
        #expect(effective.crop.enabled)
    }

    @Test func aCropTheUserSwitchedOffByHandStillGivesTheImageHalf() {
        var page = DocumentPage(scanID: UUID(), region: .right)
        page.corrections.crop = CropCorrection(quad: proposal, enabled: false, source: .manual, confidence: nil)
        let effective = PageGeometry.effectiveCorrections(for: page)
        #expect(effective.crop.quad == PageGeometry.half(of: .full, region: .right), "Von Hand ausgeschaltet heißt: kein eigener Zuschnitt")
    }

    @Test func aSinglePageWithAnUnsureProposalIsLeftAlone() {
        // Bei Einzelseiten bleibt ein unsicherer Vorschlag ein Vorschlag: ein falscher Zuschnitt verzerrt dort die ganze Seite.
        var page = DocumentPage(scanID: UUID(), region: .whole)
        page.corrections.crop = CropCorrection(quad: proposal, enabled: false, source: .automatic, confidence: 0.3)
        #expect(PageGeometry.effectiveCorrections(for: page).crop.enabled == false)
    }

    @Test func anUnsureProposalStillSplitsWhenTheMasterSwitchIsOff() {
        var page = DocumentPage(scanID: UUID(), region: .left)
        page.corrections.crop = CropCorrection(quad: proposal, enabled: false, source: .automatic, confidence: 0.4)
        page.corrections.setRotation(degrees: 3)
        page.corrections.setEnabled(false)
        page.corrections.crop = CropCorrection(quad: proposal, enabled: false, source: .automatic, confidence: 0.4)
        let effective = PageGeometry.effectiveCorrections(for: page)
        #expect(effective.enabled && effective.crop.quad == proposal)
        #expect(!effective.rotation.enabled, "Hauptschalter aus: keine Drehung, aber geteilt wird")
    }
}
