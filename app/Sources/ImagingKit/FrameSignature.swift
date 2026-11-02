import CoreGraphics
import Foundation

/// Stark verkleinertes Graustufenbild eines Vorschaubilds. Genug, um Bewegung und einen Seitenwechsel zu erkennen,
/// und billig genug, um es bei jedem Bild der Vorschau zu berechnen.
public struct FrameSignature: Equatable, Sendable {
    public static let width = 48
    public static let height = 36

    /// Zeilenweise, oben links beginnend, Werte 0 (schwarz) bis 255 (weiß).
    public let cells: [UInt8]

    /// Nur für Tests und Wiederherstellung: `cells` muss `width * height` Werte enthalten.
    public init?(cells: [UInt8]) {
        guard cells.count == Self.width * Self.height else { return nil }
        self.cells = cells
    }

    /// Mittelt das Bild über ein Raster. Das Bild darf beliebig groß sein.
    public init?(image: CGImage) {
        var buffer = [UInt8](repeating: 0, count: Self.width * Self.height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: Self.width, height: Self.height, bitsPerComponent: 8,
                                          bytesPerRow: Self.width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
            return true
        }
        guard drawn else { return nil }
        cells = buffer
    }

    /// Mittlerer Helligkeitsunterschied zweier Bilder von 0 bis 1. Reagiert auf große Bewegung, etwa eine Hand.
    public func meanDifference(to other: FrameSignature) -> Double {
        var sum = 0
        for i in 0..<cells.count { sum += abs(Int(cells[i]) - Int(other.cells[i])) }
        return Double(sum) / Double(cells.count * 255)
    }

    /// Anteil der Zellen, die sich deutlich geändert haben, von 0 bis 1. Reagiert auch auf eine neue Textseite,
    /// deren mittlere Helligkeit sich kaum ändert.
    public func changedFraction(to other: FrameSignature, cellThreshold: Double = 0.08) -> Double {
        let limit = Int(cellThreshold * 255)
        var changed = 0
        for i in 0..<cells.count where abs(Int(cells[i]) - Int(other.cells[i])) > limit { changed += 1 }
        return Double(changed) / Double(cells.count)
    }
}
