import CoreGraphics
import CoreText
import Foundation

/// Erzeugt künstliche Seiten mit Text für die Tests, ohne Scanner und ohne Dateien.
enum SyntheticPage {
    private static let words = ["Heimatverein", "Mulsum", "Chronik", "Zeitung", "Bericht", "Dorfgemeinschaft", "Versammlung", "Schützenfest",
                                "Erntedank", "Kirchenbuch", "Gemeinde", "Ortsgeschichte", "Fotografie", "Archiv", "Familie", "Hof", "Brief"]

    static func line(_ i: Int) -> String {
        (0..<9).map { words[(i * 5 + $0 * 3) % words.count] }.joined(separator: " ")
    }

    /// Weiße Seite mit Textzeilen. `tiltCounterClockwise`: Drehung des Textes gegen den Uhrzeigersinn in Grad
    /// (ein nach rechts ansteigender Text hat einen positiven Wert).
    static func textPage(width: Int = 1200, height: Int = 1600, tiltCounterClockwise: Double = 0, background: UInt8? = nil, pageScale: Double = 1) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let backgroundValue = CGFloat(background ?? 255) / 255
        context.setFillColor(gray: backgroundValue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let center = CGPoint(x: Double(width) / 2, y: Double(height) / 2)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: tiltCounterClockwise * .pi / 180)
        context.scaleBy(x: pageScale, y: pageScale)
        context.translateBy(x: -center.x, y: -center.y)

        if background != nil {
            // Die Seite selbst ist weiß und kleiner als das Bild.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 150, y: 150, width: width - 300, height: height - 300))
        }
        let font = CTFontCreateWithName("Times" as CFString, 28, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let left = background != nil ? 230.0 : 120.0
        var y = Double(height) - (background != nil ? 260 : 150)
        var i = 0
        while y > (background != nil ? 260 : 150) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: SyntheticPage.line(i), attributes: attributes))
            context.textPosition = CGPoint(x: left, y: y)
            CTLineDraw(line, context)
            y -= 42
            i += 1
        }
        return context.makeImage()!
    }

    /// Bild aus zufälligem Rauschen.
    static func noise(width: Int = 800, height: Int = 800) -> CGImage {
        var generator = SystemRandomNumberGenerator()
        var pixels = (0..<(width * height)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        }
        return context.makeImage()!
    }

    static func blank(width: Int = 800, height: Int = 800, value: UInt8 = 255) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: CGFloat(value) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
