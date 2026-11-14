import CoreGraphics
import Foundation

/// Legt zwei Teilbilder einer Seite nebeneinander: das zweite rechts vom ersten, wie die Hälften eines Plans, der in zwei Aufnahmen
/// gescannt wurde. Die Teile überlappen sich meist nicht (ein Streifen in der Faltung fehlt); die Naht ist ein Aneinanderlegen
/// an den Papierkanten, mit etwas Abstand oder Überlappung nach Bedarf.
public enum PageJoiner {
    /// - Parameters:
    ///   - gap: Abstand zwischen den Teilen als Anteil der Breite des ersten (negativ: Überlappung, der zweite liegt über dem ersten).
    ///   - shift: Verschiebung des zweiten nach unten als Anteil der Höhe des ersten (negativ: nach oben).
    ///   - background: Farbe, mit der Lücken und freie Ränder gefüllt werden (Voreinstellung Weiß, wie das Papier nach dem Aufhellen).
    /// - Returns: Das Bild beider Teile. Beide müssen mit demselben Maßstab vorliegen (dieselbe Verkleinerung ihrer Originale).
    public static func compose(first: CGImage, second: CGImage, gap: Double = 0, shift: Double = 0,
                               background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage? {
        let gapPixels = Int((gap * Double(first.width)).rounded())
        let shiftPixels = Int((shift * Double(first.height)).rounded())
        // Der zweite Teil beginnt rechts vom ersten; bei Überlappung höchstens so weit links, dass noch ein Rest von ihm bleibt.
        let secondX = max(-(second.width - 1), first.width + gapPixels)
        let firstY = max(0, -shiftPixels), secondY = max(0, shiftPixels)
        let width = max(first.width, secondX + second.width)
        let height = max(firstY + first.height, secondY + second.height)
        guard width > 0, height > 0, width * height < 400_000_000 else { return nil }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: first.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Core Graphics zeichnet von unten links: die y-Werte von oben umrechnen.
        context.draw(first, in: CGRect(x: 0, y: height - firstY - first.height, width: first.width, height: first.height))
        context.draw(second, in: CGRect(x: secondX, y: height - secondY - second.height, width: second.width, height: second.height))
        return context.makeImage()
    }
}
