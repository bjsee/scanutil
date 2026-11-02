import CoreGraphics
import Foundation
import ImageIO

extension ArchiveStore {
    /// Verkleinerte Ansicht eines Originals. Das Original bleibt unberührt.
    /// Entpackt das Bild mit ImageIO, ohne es vollständig als 24-Megapixel-Bitmap zu halten.
    public func thumbnail(for record: ScanRecord, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(originalURL(for: record) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
