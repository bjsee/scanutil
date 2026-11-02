import ArchiveKit
import CoreGraphics
import Foundation
import ImageIO
import ImagingKit
import UniformTypeIdentifiers

/// Baut aus einem Dokument ein PDF. Die Originale bleiben unberührt: jede Seite wird aus Original und
/// Korrekturen neu berechnet, als JPEG kodiert und seitenweise geschrieben, damit auch ein dickes Buch
/// nicht im Speicher liegt.
public struct PDFExporter: Sendable {
    public let store: ArchiveStore

    public init(store: ArchiveStore) {
        self.store = store
    }

    /// Schreibt das PDF atomar an `destination`; eine vorhandene Datei wird ersetzt.
    /// Bricht die umgebende Task ab, endet der Export mit `CancellationError` und hinterlässt keine Datei.
    /// - Parameter progress: wird nach jeder Seite mit (fertige Seiten, alle Seiten) aufgerufen.
    public func export(_ document: ScanDocument, to destination: URL, options: ExportOptions = .archive,
                       progress: (Int, Int) -> Void = { _, _ in }) throws {
        guard !document.pages.isEmpty else { throw ExportError.emptyDocument }
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try write(document, to: temporary, options: options, progress: progress)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    private func write(_ document: ScanDocument, to url: URL, options: ExportOptions,
                       progress: (Int, Int) -> Void) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, Self.info(for: document) as CFDictionary)
        else { throw ExportError.writeFailed(url.path) }

        let total = document.pages.count
        for (index, page) in document.pages.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let (jpeg, pageSize) = try renderedJPEG(page, number: index + 1, options: options)
                try draw(jpeg: jpeg, pageSize: pageSize, number: index + 1, in: context)
            }
            progress(index + 1, total)
        }
        context.closePDF()
    }

    /// Lädt das Original, wendet die Korrekturen an, verkleinert auf Wunsch und kodiert als JPEG.
    private func renderedJPEG(_ page: DocumentPage, number: Int, options: ExportOptions) throws -> (jpeg: Data, pageSize: CGSize) {
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
        return (data as Data, pageSize)
    }

    /// Schreibt das JPEG als eigene PDF-Seite. Die Größe der Seite folgt aus der Auflösung des Originals,
    /// nicht aus dem verkleinerten Bild: eine Seite behält ihre Größe, egal welches Preset gilt.
    private func draw(jpeg: Data, pageSize: CGSize, number: Int, in context: CGContext) throws {
        guard let provider = CGDataProvider(data: jpeg as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent)
        else { throw ExportError.renderFailed(pageNumber: number) }

        var box = CGRect(origin: .zero, size: pageSize)
        let boxData = withUnsafeBytes(of: &box) { Data($0) }
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        context.draw(image, in: box)
        context.endPDFPage()
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
