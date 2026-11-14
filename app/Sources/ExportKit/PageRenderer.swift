import ArchiveKit
import CoreGraphics
import Foundation
import ImagingKit

/// Rechnet eine Seite aus ihren Originalen und Korrekturen. Bei einer Seite aus zwei Scans (`DocumentPage.joined`) wird jeder Teil mit
/// seinen eigenen Korrekturen gerechnet und danach nebeneinandergelegt. Der eine Weg für Vorschau, Zoom, Texterkennung und PDF.
public enum PageRenderer {
    /// - Parameter image: liefert zu einer Scan-ID das Bild des Scans. Bei einer verbundenen Seite beide mit derselben Verkleinerung
    ///   ihrer Originale, sonst passen die Maßstäbe der Teile nicht zusammen. `nil`: Der Scan fehlt, die Seite lässt sich nicht rechnen.
    public static func render(_ page: DocumentPage, image: (UUID) -> CGImage?) -> CGImage? {
        guard let source = image(page.scanID),
              let first = CorrectionRenderer.render(source, corrections: PageGeometry.effectiveCorrections(for: page)) else { return nil }
        guard let part = page.joined else { return first }
        guard let other = image(part.scanID), let rendered = CorrectionRenderer.render(other, corrections: part.corrections) else { return nil }
        // Die Perspektivkorrektur rechnet ein schiefes oder zu kleines Viereck auf eine andere Größe um: Beide Teile sollen im selben
        // Maßstab liegen wie ihre Originale, sonst stünde ein Teil größer neben dem anderen.
        let second = matchScale(rendered,
                                of: scale(of: rendered, source: other, corrections: part.corrections),
                                to: scale(of: first, source: source, corrections: PageGeometry.effectiveCorrections(for: page)))
        return PageJoiner.compose(first: first, second: second, gap: part.gap, shift: part.shift)
    }

    /// Um welchen Faktor das gerechnete Bild gegenüber dem Original skaliert ist: Größe nach Zuschnitt und Ausrichtung, geteilt durch
    /// die Größe, die der Zuschnitt ohne Skalierung hätte. Ohne Perspektive etwa 1; die Drehung beschneidet ein paar Prozent.
    static func scale(of rendered: CGImage, source: CGImage, corrections: Corrections) -> Double {
        var w = Double(source.width), h = Double(source.height)
        if corrections.enabled, corrections.crop.enabled, let q = corrections.crop.quad {
            let xs = [q.topLeft.x, q.topRight.x, q.bottomRight.x, q.bottomLeft.x], ys = [q.topLeft.y, q.topRight.y, q.bottomRight.y, q.bottomLeft.y]
            w *= (xs.max() ?? 1) - (xs.min() ?? 0); h *= (ys.max() ?? 1) - (ys.min() ?? 0)
        }
        if corrections.quarterTurns % 2 != 0 { swap(&w, &h) }
        guard w > 1, h > 1 else { return 1 }
        return (Double(rendered.width) / w + Double(rendered.height) / h) / 2
    }

    /// Bringt `image`, dessen Maßstab `scale` ist, auf den Maßstab `target`. Kleine Unterschiede (unter 5 %, etwa vom Beschnitt durch
    /// die Drehung) bleiben, damit nichts ohne Not neu gerechnet wird.
    static func matchScale(_ image: CGImage, of scale: Double, to target: Double) -> CGImage {
        guard scale > 0.01, target > 0.01 else { return image }
        let factor = target / scale
        guard abs(factor - 1) > 0.05 else { return image }
        let w = max(1, Int((Double(image.width) * factor).rounded())), h = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }
}
