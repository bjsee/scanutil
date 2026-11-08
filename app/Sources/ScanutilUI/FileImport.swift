import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Liest Dateien, die statt eines Scans in die Schnellablage kommen: Bilder und PDFs.
enum FileImport {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "bmp"]
    /// PDF-Seiten werden mit dieser Auflösung in Bilder verwandelt …
    static let pdfDPI = 300.0
    /// … höchstens bis zu dieser längsten Kante (große Pläne würden sonst Hunderte Megapixel).
    static let maxLongSide = 4200.0

    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }
    static func isSupported(_ url: URL) -> Bool { isPDF(url) || imageExtensions.contains(url.pathExtension.lowercased()) }

    /// Die Seiten der Datei als Bilder, in Reihenfolge: ein Bild für eine Bilddatei, je Seite eines für ein PDF.
    /// Leer, wenn die Datei sich nicht lesen lässt.
    static func images(from url: URL) -> [CGImage] {
        isPDF(url) ? pdfPages(url) : image(url).map { [$0] } ?? []
    }

    /// Ein Bild mit richtiger Ausrichtung (EXIF), höchstens `maxLongSide` lang.
    static func image(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 8000,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func pdfPages(_ url: URL) -> [CGImage] {
        guard let document = PDFDocument(url: url), !document.isLocked else { return [] }
        return (0..<document.pageCount).compactMap { index in document.page(at: index).flatMap(render) }
    }

    /// Eine PDF-Seite auf weißem Grund, mit ihrer Drehung.
    private static func render(_ page: PDFPage) -> CGImage? {
        var bounds = page.bounds(for: .mediaBox)
        if page.rotation % 180 != 0 { bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(pdfDPI / 72, maxLongSide / max(bounds.width, bounds.height))
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// Kodiert ein Bild verlustfrei als PNG, wie die Aufnahmen des Scanners.
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Sammelt die Dateien aus abgelegten Einträgen. Die Rückmeldung kommt, sobald alle Einträge gelesen sind.
enum FileDrop {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [(Int, URL)] = []
        func add(_ index: Int, _ url: URL) { lock.withLock { urls.append((index, url)) } }
        /// In der Reihenfolge, in der sie abgelegt wurden.
        var ordered: [URL] { lock.withLock { urls.sorted { $0.0 < $1.0 }.map(\.1) } }
    }

    static func urls(from providers: [NSItemProvider], completion: @escaping @Sendable ([URL]) -> Void) {
        let collector = Collector()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collector.add(index, url) }
                else if let url = item as? URL { collector.add(index, url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(collector.ordered) }
    }
}
