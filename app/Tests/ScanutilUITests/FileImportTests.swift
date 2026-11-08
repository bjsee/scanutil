import AppKit
import ArchiveKit
import CoreGraphics
import ExportKit
import Foundation
import ImageIO
import PDFKit
import ScannerKit
import Testing
import UniformTypeIdentifiers
@testable import ScanutilUI

/// Erzeugt Testdateien: PDFs mit Text, PNG und JPEG.
private enum Fixtures {
    static func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func pdf(at url: URL, pages: Int, size: CGSize = CGSize(width: 595, height: 842), rotation: Int = 0) {
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for n in 1...pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            context.fill(CGRect(x: 40, y: size.height - 80, width: 300, height: 24))
            _ = n
            context.endPDFPage()
        }
        context.closePDF()
        if rotation != 0, let doc = PDFDocument(url: url) {
            for i in 0..<doc.pageCount { doc.page(at: i)?.rotation = rotation }
            doc.write(to: url)
        }
    }

    static func image(at url: URL, type: UTType = .png, width: Int = 200, height: Int = 100) {
        let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.8, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = c.makeImage()!
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, image, nil)
        CGImageDestinationFinalize(d)
    }
}

@Suite("Dateien lesen")
struct FileImportTests {
    @Test func onlyImagesAndPDFsAreSupported() {
        for ext in ["pdf", "PDF", "png", "jpg", "JPEG", "tif", "heic"] { #expect(FileImport.isSupported(URL(fileURLWithPath: "/x/datei.\(ext)")), "\(ext)") }
        for ext in ["docx", "txt", "zip", "mov", ""] { #expect(!FileImport.isSupported(URL(fileURLWithPath: "/x/datei.\(ext)")), "\(ext)") }
    }

    @Test func aPDFBecomesOneImagePerPageAt300DPI() {
        let dir = Fixtures.dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.pdf"); Fixtures.pdf(at: url, pages: 3)
        let images = FileImport.images(from: url)
        #expect(images.count == 3)
        #expect(abs(images[0].width - 2480) <= 1 && abs(images[0].height - 3508) <= 1, "A4 mit 300 dpi: \(images[0].width)×\(images[0].height)")
    }

    @Test func aHugePDFPageIsLimitedInSize() {
        let dir = Fixtures.dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plan.pdf"); Fixtures.pdf(at: url, pages: 1, size: CGSize(width: 3000, height: 2000))
        let image = FileImport.images(from: url)[0]
        #expect(max(image.width, image.height) <= 4200, "\(image.width)×\(image.height)")
        #expect(abs(Double(image.width) / Double(image.height) - 1.5) < 0.01, "Seitenverhältnis bleibt")
    }

    @Test func aRotatedPDFPageComesOutTheRightWayRound() {
        let dir = Fixtures.dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("quer.pdf"); Fixtures.pdf(at: url, pages: 1, rotation: 90)
        let image = FileImport.images(from: url)[0]
        #expect(image.width > image.height, "Um 90° gedreht ist die Seite quer: \(image.width)×\(image.height)")
    }

    @Test func aPDFPageIsOnWhiteNotTransparent() throws {
        let dir = Fixtures.dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.pdf"); Fixtures.pdf(at: url, pages: 1)
        let image = FileImport.images(from: url)[0]
        var pixel = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: -image.width + 5, y: -5, width: image.width, height: image.height))     // unten rechts, leer
        #expect(pixel[0] > 250 && pixel[1] > 250 && pixel[2] > 250 && pixel[3] == 255)
    }

    @Test func imagesKeepTheirSizeAndOtherFilesGiveNothing() throws {
        let dir = Fixtures.dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png"); Fixtures.image(at: png)
        let jpg = dir.appendingPathComponent("b.jpg"); Fixtures.image(at: jpg, type: .jpeg, width: 80, height: 60)
        let a = try #require(FileImport.images(from: png).first), b = try #require(FileImport.images(from: jpg).first)
        #expect(a.width == 200 && a.height == 100)
        #expect(b.width == 80 && b.height == 60)
        let junk = dir.appendingPathComponent("kaputt.png"); try Data("kein Bild".utf8).write(to: junk)
        #expect(FileImport.images(from: junk).isEmpty)
        #expect(FileImport.images(from: dir.appendingPathComponent("fehlt.pdf")).isEmpty)
        #expect(FileImport.pngData(FileImport.images(from: png)[0])?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }
}

private struct TextRecognizerStub: TextRecognizer {
    let lines: [String]
    func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        lines.enumerated().map { RecognizedLine(text: $1, box: CGRect(x: 0.1, y: 0.9 - Double($0) * 0.05, width: 0.5, height: 0.03)) }
    }
}

@MainActor
@Suite("Dateien in der Schnellablage")
struct FileImportModelTests {
    private func makeModel(lines: [String] = ["Tierarztpraxis Dr. Meier"]) async -> (AppModel, URL, URL) {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-importmodel-\(UUID().uuidString)")
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: ArchiveStore(root: archive), thumbnailSize: 256,
                             recognizer: TextRecognizerStub(lines: lines), sound: SilentSound(), defaults: nil)
        await model.connect()
        return (model, archive, Fixtures.dir())
    }

    @Test func droppedFilesBecomeAnInboxWithOneDocumentPerImageAndOnePerPDF() async throws {
        let (model, archive, dir) = await makeModel(); defer { for u in [archive, dir] { try? FileManager.default.removeItem(at: u) } }
        let target = model.addInboxTarget(path: dir.appendingPathComponent("ziel").path, label: "Privat")
        let png = dir.appendingPathComponent("brief.png"); Fixtures.image(at: png)
        let pdf = dir.appendingPathComponent("rechnung.pdf"); Fixtures.pdf(at: pdf, pages: 2)
        let id = try #require(await model.importFiles([png, pdf]))
        let doc = try #require(model.latestDocument(id: id))
        #expect(doc.isInbox && !model.isInboxActive, "Eine Schnellablage zum Prüfen, keine laufende Aufnahme")
        #expect(doc.pages.count == 3)
        #expect(doc.groups.map(\.pageIDs.count) == [1, 2], "Die Seiten einer PDF-Datei sind ein Dokument")
        #expect(doc.groups.allSatisfy { doc.target(of: $0) == target.id }, "Gewähltes Ziel")
        #expect(model.openInboxes.map(\.id) == [id])
        await model.disconnect()
    }

    @Test func importedFilesGetNamesFromTheirTextLikeScans() async throws {
        let (model, archive, dir) = await makeModel(); defer { for u in [archive, dir] { try? FileManager.default.removeItem(at: u) } }
        let png = dir.appendingPathComponent("a.png"); Fixtures.image(at: png)
        let id = try #require(await model.importFiles([png]))
        let doc = try #require(model.latestDocument(id: id))
        #expect(doc.name(of: doc.groups[0]) == "Tierarztpraxis Dr. Meier", "Name aus der Texterkennung")
        #expect(model.inboxFileStem(documentID: id, group: doc.groups[0]) == "\(InboxNaming.prefix(for: Date())) Tierarztpraxis Dr. Meier")
        await model.disconnect()
    }

    @Test func importedDocumentsCanBeFiledAsSearchablePDFs() async throws {
        let (model, archive, dir) = await makeModel(); defer { for u in [archive, dir] { try? FileManager.default.removeItem(at: u) } }
        let out = dir.appendingPathComponent("ablage")
        model.inboxDirectory = out
        let pdf = dir.appendingPathComponent("x.pdf"); Fixtures.pdf(at: pdf, pages: 2)
        let id = try #require(await model.importFiles([pdf]))
        let urls = await model.fileInbox(documentID: id)
        #expect(urls.count == 1 && PDFDocument(url: urls[0])?.pageCount == 2)
        #expect(urls[0].lastPathComponent == "\(InboxNaming.prefix(for: Date())) Tierarztpraxis Dr. Meier.pdf")
        #expect((PDFDocument(url: urls[0])?.string ?? "").contains("Tierarztpraxis"), "Mit Texterkennung durchsuchbar")
        await model.disconnect()
    }

    @Test func duringARunningInboxFilesAreAddedAtTheEndAndNamedWithFinish() async throws {
        let (model, archive, dir) = await makeModel(); defer { for u in [archive, dir] { try? FileManager.default.removeItem(at: u) } }
        model.startInbox(); await model.scan()
        let running = try #require(model.series?.id)
        let png = dir.appendingPathComponent("a.png"); Fixtures.image(at: png)
        let id = try #require(await model.importFiles([png]))
        #expect(id == running, "In die laufende Schnellablage")
        #expect(model.isInboxActive && model.series?.pages.count == 2 && model.series?.groups.count == 2)
        #expect(model.series.flatMap { $0.name(of: $0.groups[1]) } == nil, "Namen kommen mit „Fertig“")
        let finished = try #require(await model.finishInbox())
        let doc = try #require(model.latestDocument(id: finished))
        #expect(doc.groups.allSatisfy { doc.name(of: $0) != nil })
        await model.disconnect()
    }

    @Test func unsupportedAndUnreadableFilesAreReportedAndSkipped() async throws {
        let (model, archive, dir) = await makeModel(); defer { for u in [archive, dir] { try? FileManager.default.removeItem(at: u) } }
        let txt = dir.appendingPathComponent("notiz.txt"); try Data("x".utf8).write(to: txt)
        #expect(await model.importFiles([txt]) == nil)
        #expect(model.log.contains { $0.level == .warning && $0.text.contains("notiz.txt") })
        #expect(model.savedDocuments.isEmpty, "Ohne brauchbare Datei entsteht keine Schnellablage")

        let junk = dir.appendingPathComponent("kaputt.png"); try Data("kein Bild".utf8).write(to: junk)
        let good = dir.appendingPathComponent("gut.png"); Fixtures.image(at: good)
        let id = try #require(await model.importFiles([junk, good, dir]))      // dazu ein Ordner
        #expect(model.latestDocument(id: id)?.pages.count == 1)
        #expect(model.log.contains { $0.level == .error && $0.text.contains("kaputt.png") })
        await model.disconnect()
    }

    @Test func originalsOfImportedFilesAreStoredInTheArchive() async throws {
        let (model, archive, dir) = await makeModel(); defer { for u in [archive, dir] { try? FileManager.default.removeItem(at: u) } }
        let png = dir.appendingPathComponent("a.png"); Fixtures.image(at: png, width: 300, height: 200)
        _ = await model.importFiles([png])
        let records = try ArchiveStore(root: archive).allRecords()
        #expect(records.count == 1 && records[0].original.width == 300 && records[0].original.height == 200)
        #expect(records[0].capture.device.name == "Import", "Die Herkunft ist als Import vermerkt")
        await model.disconnect()
    }
}
