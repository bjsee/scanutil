import ArchiveKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ImagingKit
import UniformTypeIdentifiers

/// Baut aus einem Dokument ein PDF. Die Originale bleiben unberührt: jede Seite wird aus Original und
/// Korrekturen neu berechnet, als JPEG kodiert und seitenweise geschrieben, damit auch ein dickes Buch
/// nicht im Speicher liegt.
public struct PDFExporter: Sendable {
    public let store: ArchiveStore
    private let recognizer: any TextRecognizer

    public init(store: ArchiveStore, recognizer: any TextRecognizer = VisionTextRecognizer()) {
        self.store = store
        self.recognizer = recognizer
    }

    /// Schreibt das PDF atomar an `destination`; eine vorhandene Datei wird ersetzt.
    /// Bricht die umgebende Task ab, endet der Export mit `CancellationError` und hinterlässt keine Datei.
    /// - Parameter progress: wird nach jeder Seite mit (fertige Seiten, alle Seiten) aufgerufen.
    @discardableResult
    public func export(_ document: ScanDocument, to destination: URL, options: ExportOptions = .archive,
                       progress: (Int, Int) -> Void = { _, _ in }) throws -> ExportReport {
        guard !document.pages.isEmpty else { throw ExportError.emptyDocument }
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            let report = try write(document, to: temporary, options: options, progress: progress)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
            return report
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    private func write(_ document: ScanDocument, to url: URL, options: ExportOptions,
                       progress: (Int, Int) -> Void) throws -> ExportReport {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, Self.info(for: document) as CFDictionary)
        else { throw ExportError.writeFailed(url.path) }

        let total = document.pages.count
        var failures: [Int] = []
        var lineCount = 0
        for (index, page) in document.pages.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let rendered = try renderedJPEG(page, number: index + 1, options: options)
                var lines: [RecognizedLine] = []
                if let ocrImage = rendered.ocrImage {
                    do { lines = try recognizer.recognize(ocrImage, languages: options.ocrLanguages) }
                    catch { failures.append(index + 1) }
                }
                lineCount += lines.count
                try draw(jpeg: rendered.jpeg, pageSize: rendered.pageSize, lines: lines, number: index + 1, in: context)
            }
            progress(index + 1, total)
        }
        context.closePDF()
        return ExportReport(pageCount: total, ocrFailures: failures, recognizedLines: lineCount)
    }

    /// Lädt das Original, wendet die Korrekturen an, verkleinert auf Wunsch und kodiert als JPEG.
    private func renderedJPEG(_ page: DocumentPage, number: Int, options: ExportOptions) throws -> (jpeg: Data, pageSize: CGSize, ocrImage: CGImage?) {
        let record = try store.load(id: page.scanID)
        let originalURL = store.originalURL(for: record)
        guard let source = CGImageSourceCreateWithURL(originalURL as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ExportError.originalUnreadable(record.original.path) }

        let corrections = PageGeometry.effectiveCorrections(for: page)
        guard let corrected = CorrectionRenderer.render(original, corrections: corrections) else {
            throw ExportError.renderFailed(pageNumber: number)
        }
        guard let opaque = Self.opaque(corrected, maxLongSide: options.maxLongSide) else {
            throw ExportError.renderFailed(pageNumber: number)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ExportError.renderFailed(pageNumber: number) }
        CGImageDestinationAddImage(destination, opaque,
                                   [kCGImageDestinationLossyCompressionQuality: options.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.renderFailed(pageNumber: number) }
        // Größe der Seite aus dem Bild vor dem Verkleinern: 72 Punkte sind ein Zoll.
        let pageSize = CGSize(width: Double(corrected.width) / options.dpi * 72,
                              height: Double(corrected.height) / options.dpi * 72)
        // Texterkennung auf dem Bild der Seite, auf höchstens `ocrMaxLongSide` verkleinert.
        let ocrImage = options.ocr ? Self.opaque(corrected, maxLongSide: ExportOptions.ocrMaxLongSide) : nil
        return (data as Data, pageSize, ocrImage)
    }

    /// Schreibt das JPEG als eigene PDF-Seite. Die Größe der Seite folgt aus der Auflösung des Originals,
    /// nicht aus dem verkleinerten Bild: eine Seite behält ihre Größe, egal welches Preset gilt.
    private func draw(jpeg: Data, pageSize: CGSize, lines: [RecognizedLine], number: Int, in context: CGContext) throws {
        guard let provider = CGDataProvider(data: jpeg as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent)
        else { throw ExportError.renderFailed(pageNumber: number) }

        var box = CGRect(origin: .zero, size: pageSize)
        let boxData = withUnsafeBytes(of: &box) { Data($0) }
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        context.draw(image, in: box)
        Self.drawInvisibleText(lines, on: box, in: context)
        context.endPDFPage()
    }

    /// Legt den erkannten Text unsichtbar über das Bild: Er lässt sich suchen und kopieren, ohne zu stören.
    /// Jede Zeile wird in der Breite ihres Rahmens gesetzt, damit die Markierung am Bild liegt.
    static func drawInvisibleText(_ lines: [RecognizedLine], on page: CGRect, in context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let box = CGRect(x: line.box.minX * page.width, y: line.box.minY * page.height,
                             width: line.box.width * page.width, height: line.box.height * page.height)
            guard box.width > 0.5, box.height > 0.5 else { continue }
            // Breite der Zeile bei Schriftgröße 100; daraus folgt die Größe, bei der sie in den Rahmen passt.
            func typeset(at size: CGFloat) -> CTLine {
                let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                return CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.init(kCTFontAttributeName as String): font]))
            }
            let reference = CTLineGetTypographicBounds(typeset(at: 100), nil, nil, nil)
            guard reference > 0 else { continue }
            // Nie stauchen: PDFKit liest gestauchten Text mit Lücken zwischen den Buchstaben („S c h ü tz e n“),
            // gemessen. Ist die Zeile für die Höhe zu breit, wird die Schrift kleiner, nicht schmaler.
            let size = min(box.height, box.width / CGFloat(reference) * 100)
            let ctLine = typeset(at: size)
            let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let stretch = min(10, max(1, box.width / natural))
            context.textMatrix = CGAffineTransform(a: stretch, b: 0, c: 0, d: 1, tx: box.minX, ty: box.minY + box.height * 0.22)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }

    static func info(for document: ScanDocument) -> [CFString: Any] {
        var info: [CFString: Any] = [kCGPDFContextTitle: document.title, kCGPDFContextCreator: "scanutil"]
        if let author = document.metadata.author { info[kCGPDFContextAuthor] = author }
        if let signature = document.metadata.signature { info[kCGPDFContextSubject] = signature }
        if !document.metadata.keywords.isEmpty { info[kCGPDFContextKeywords] = document.metadata.keywords.joined(separator: ", ") }
        return info
    }

    /// Zeichnet das Bild in eine undurchsichtige RGB-Fläche, verkleinert dabei auf Wunsch und entfernt den Alphakanal.
    static func opaque(_ image: CGImage, maxLongSide: Int?) -> CGImage? {
        let (w, h) = (image.width, image.height)
        var scale = 1.0
        if let limit = maxLongSide, max(w, h) > limit { scale = Double(limit) / Double(max(w, h)) }
        let target = (width: max(1, Int((Double(w) * scale).rounded())), height: max(1, Int((Double(h) * scale).rounded())))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: target.width, height: target.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        return context.makeImage()
    }
}
