import CoreGraphics
import CoreImage
import Foundation

/// Wendet Korrekturen auf ein Bild an. Das Original wird nie verändert, es entsteht immer ein neues Bild.
/// Arbeitet mit normierten Koordinaten und liefert deshalb für Vorschau und Original dasselbe Ergebnis.
public enum CorrectionRenderer {
    private static let context = CIContext()

    /// Reihenfolge: erst Zuschnitt mit Perspektive, dann Drehung, dann Beschnitt auf das größte Rechteck ohne leere Ecken.
    public static func render(_ image: CGImage, corrections: Corrections) -> CGImage? {
        guard corrections.enabled else { return image }
        // Zuerst die Hände: Zuschnitt und Drehung arbeiten dann auf dem bereinigten Bild.
        var image = image
        if corrections.handRemoval.enabled, let data = corrections.handRemoval.mask, let mask = HandMask(pngData: data),
           let cleaned = HandRemover.apply(to: image, mask: mask) {
            image = cleaned
        }
        var ci = CIImage(cgImage: image)
        let width = Double(image.width), height = Double(image.height)

        if corrections.crop.enabled, let quad = corrections.crop.quad {
            // Core Image rechnet mit Ursprung unten links.
            func p(_ n: NormalizedPoint) -> CIVector { CIVector(x: n.x * width, y: (1 - n.y) * height) }
            let filter = CIFilter(name: "CIPerspectiveCorrection")!
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(p(quad.topLeft), forKey: "inputTopLeft")
            filter.setValue(p(quad.topRight), forKey: "inputTopRight")
            filter.setValue(p(quad.bottomLeft), forKey: "inputBottomLeft")
            filter.setValue(p(quad.bottomRight), forKey: "inputBottomRight")
            guard let corrected = filter.outputImage else { return nil }
            ci = corrected.transformed(by: CGAffineTransform(translationX: -corrected.extent.minX, y: -corrected.extent.minY))
        }

        if corrections.rotation.enabled, abs(corrections.rotation.degrees) > 0.001 {
            let size = ci.extent.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // Im Uhrzeigersinn: bei nach oben zeigender y-Achse ein negativer Winkel.
            let radians = -corrections.rotation.degrees * .pi / 180
            // Drehung um den Mittelpunkt, ausdrücklich als Matrix: Verkettungen von `rotated` und `translatedBy`
            // ergaben eine Drehung um den Ursprung und damit leere Ecken im Ergebnis.
            let cosA = CGFloat(cos(radians)), sinA = CGFloat(sin(radians))
            let transform = CGAffineTransform(
                a: cosA, b: sinA, c: -sinA, d: cosA,
                tx: center.x - center.x * cosA + center.y * sinA,
                ty: center.y - center.x * sinA - center.y * cosA
            )
            let inner = largestInscribedRect(width: size.width, height: size.height, angle: abs(radians))
            let crop = CGRect(x: center.x - inner.width / 2, y: center.y - inner.height / 2, width: inner.width, height: inner.height)
            ci = ci.transformed(by: transform).cropped(to: crop)
        }

        let extent = ci.extent.integral
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        // Zuletzt das Papier: Es wird auf der fertig zugeschnittenen Seite gemessen, ohne das schwarze Tuch ringsum.
        if corrections.tone.enabled {
            ci = ToneNormalizer.apply(to: ci.cropped(to: extent))
            return ToneNormalizer.context.createCGImage(ci, from: extent, format: .RGBA8, colorSpace: ToneNormalizer.srgb)
        }
        return context.createCGImage(ci, from: extent)
    }

    /// Größtes achsenparalleles Rechteck gleichen Seitenverhältnisses innerhalb eines um `angle` gedrehten Rechtecks.
    static func largestInscribedRect(width w: Double, height h: Double, angle: Double) -> CGSize {
        guard angle > 1e-9 else { return CGSize(width: w, height: h) }
        let widthIsLonger = w >= h
        let longSide = widthIsLonger ? w : h, shortSide = widthIsLonger ? h : w
        let sinA = sin(angle), cosA = cos(angle)
        if shortSide <= 2 * sinA * cosA * longSide || abs(sinA - cosA) < 1e-10 {
            let x = 0.5 * shortSide
            return widthIsLonger ? CGSize(width: x / sinA, height: x / cosA) : CGSize(width: x / cosA, height: x / sinA)
        }
        let cos2A = cosA * cosA - sinA * sinA
        return CGSize(width: (w * cosA - h * sinA) / cos2A, height: (h * cosA - w * sinA) / cos2A)
    }
}
