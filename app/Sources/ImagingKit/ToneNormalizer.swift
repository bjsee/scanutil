import CoreGraphics
import CoreImage
import Foundation

/// Rechnet den Helligkeitsverlauf einer Papierseite heraus (Schatten zum Falz, ungleichmäßiges Licht) und macht das Papier hell.
///
/// Gemessen wird auf einer verkleinerten Fassung: In jedem Block die Helligkeit des Papiers (ein hoher Perzentilwert, denn Schrift
/// ist dunkel und macht nur einen kleinen Teil aus). Daraus entsteht ein weicher Verlauf, durch den das Bild geteilt wird. Große
/// dunkle Flächen (Zeichnungen, Fotos) würden dabei aufgehellt; deshalb bleibt der Verlauf über einer Untergrenze, und die
/// Verstärkung ist nach oben begrenzt. Alle Farbkanäle bekommen dieselbe Verstärkung: Der Ton des Papiers bleibt, es wird nur heller.
public enum ToneNormalizer {
    /// Stärke und Radius des Schärfens am Ende (siehe `apply`).
    static let sharpenIntensity = 0.6
    static let sharpenRadiusFactor = 1.2

    /// Ein Core-Image-Kontext, der die Werte nicht umrechnet: Alles rechnet mit den Zahlen des sRGB-Bildes, wie die Messung auf der
    /// verkleinerten Fassung. Mit der Voreinstellung (lineares Arbeitsfarbmodell) stimmten Messung und Rechnung nicht überein,
    /// und das Ergebnis wurde grau.
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// So hell wird das Papier (1 = reines Weiß). Etwas darunter, damit nichts ausbrennt.
    public static let paperTarget: Float = 0.95
    /// Der Verlauf fällt nie unter diesen Anteil des hellsten Papiers: begrenzt die Verstärkung (hier auf etwa das 1,9-fache).
    static let floorShare: Float = 0.52
    /// Längste Kante der verkleinerten Fassung, auf der gemessen wird.
    static let workingSize: CGFloat = 640

    /// Der Verlauf als Gleitkommafeld mit Werten von `floorShare·P` bis `P`, bezogen auf 0…1 (`P` = Helligkeit des hellsten Papiers).
    /// - Parameters:
    ///   - luminance: Helligkeit je Bildpunkt, 0…1, zeilenweise.
    /// - Returns: Feld gleicher Größe; `nil`, wenn das Bild keine brauchbare Papierfläche enthält (zu dunkel).
    static func backgroundField(luminance: [Float], width w: Int, height h: Int) -> [Float]? {
        guard w >= 8, h >= 8, luminance.count == w * h else { return nil }
        let block = max(8, min(w, h) / 24)
        let bx = (w + block - 1) / block, by = (h + block - 1) / block
        var grid = [Float](repeating: 0, count: bx * by)
        for gy in 0..<by {
            for gx in 0..<bx {
                var values: [Float] = []
                values.reserveCapacity(block * block)
                for y in (gy * block)..<min(h, (gy + 1) * block) { for x in (gx * block)..<min(w, (gx + 1) * block) { values.append(luminance[y * w + x]) } }
                values.sort()
                grid[gy * bx + gx] = values[values.count * 85 / 100]        // Papier: heller als Schrift und Schatten der Schrift
            }
        }
        var sorted = grid; sorted.sort()
        let paper = sorted[sorted.count * 9 / 10]
        guard paper > 0.18 else { return nil }
        let floor = floorShare * paper
        for i in grid.indices { grid[i] = min(max(grid[i], floor), paper) }
        // Weich machen: zweimal 3×3-Mittel auf dem Raster.
        for _ in 0..<2 {
            var next = grid
            for gy in 0..<by { for gx in 0..<bx {
                var sum: Float = 0, count: Float = 0
                for dy in -1...1 { for dx in -1...1 {
                    let x = gx + dx, y = gy + dy
                    if x >= 0, x < bx, y >= 0, y < by { sum += grid[y * bx + x]; count += 1 }
                } }
                next[gy * bx + gx] = sum / count
            } }
            grid = next
        }
        // Auf Bildgröße bringen, bilinear zwischen den Blockmitten.
        var field = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let fy = max(0, min(Float(by - 1), (Float(y) + 0.5) / Float(block) - 0.5)); let y0 = Int(fy), y1 = min(by - 1, y0 + 1), ty = fy - Float(y0)
            for x in 0..<w {
                let fx = max(0, min(Float(bx - 1), (Float(x) + 0.5) / Float(block) - 0.5)); let x0 = Int(fx), x1 = min(bx - 1, x0 + 1), tx = fx - Float(x0)
                let top = grid[y0 * bx + x0] * (1 - tx) + grid[y0 * bx + x1] * tx
                let bottom = grid[y1 * bx + x0] * (1 - tx) + grid[y1 * bx + x1] * tx
                field[y * w + x] = top * (1 - ty) + bottom * ty
            }
        }
        return field
    }

    /// Wendet das Aufhellen auf ein Bild an. Gibt das Bild unverändert zurück, wenn keine Papierfläche zu messen ist.
    static func apply(to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width >= 16, extent.height >= 16 else { return image }
        let scale = min(1, workingSize / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int((extent.width * scale).rounded()), h = Int((extent.height * scale).rounded())
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &rgba, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBA8, colorSpace: nil)
        var luminance = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            luminance[i] = (0.299 * Float(rgba[i * 4]) + 0.587 * Float(rgba[i * 4 + 1]) + 0.114 * Float(rgba[i * 4 + 2])) / 255
        }
        guard let field = backgroundField(luminance: luminance, width: w, height: h) else { return image }

        // Die Verstärkung 1/Verlauf liegt zwischen 1 und etwa 1,9: halbiert als Graubild gespeichert (0,5…1), dann multipliziert
        // und wieder verdoppelt. Core Image rechnet dazwischen in Gleitkomma, nichts wird vorzeitig abgeschnitten.
        let peak = field.max() ?? 1
        var gain = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { gain[i] = UInt8(max(0, min(255, (peak / field[i]) / 2 * 255 + 0.5))) }
        guard let provider = CGDataProvider(data: Data(gain) as CFData),
              let gainImage = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                      decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return image }
        let up = CIImage(cgImage: gainImage, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h)))
            .samplingLinear()
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        let multiplied = image.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: up])
        // ×2 (die Halbierung rückgängig) und auf das Papierziel bringen: das hellste Papier (Verlauf = Spitze) wird `paperTarget`.
        // Die Spitze selbst liegt unter 1; der Anteil macht sie ebenfalls zu `paperTarget`.
        let factor = CGFloat(2 * paperTarget / peak)
        let scaled = multiplied.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        // Kräftigere Schrift: Mitteltöne etwas abdunkeln, Weiß und Schwarz bleiben.
        let curved = scaled.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.20), "inputPoint2": CIVector(x: 0.5, y: 0.47),
            "inputPoint3": CIVector(x: 0.75, y: 0.76), "inputPoint4": CIVector(x: 1, y: 1),
        ])
        // Schärfen: Zuschnitt und Drehung rechnen das Bild zweimal um und verlieren dabei etwas Schärfe (bilinear etwa 14 %).
        // Ein milder Schärfen-Schritt gleicht das aus. Der Radius hängt von der Seitengröße ab: etwa 1/1200 der längeren Kante.
        let radius = max(1.0, Double(max(extent.width, extent.height)) / 1200 * sharpenRadiusFactor)
        return curved.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: sharpenIntensity])
            .cropped(to: extent)
    }
}
