import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Erzeugt künstliche Seiten mit Text für Tests und den Demomodus der App, ohne Scanner und ohne Dateien.
public enum SyntheticPage {
    private static let words = ["Heimatverein", "Mulsum", "Chronik", "Zeitung", "Bericht", "Dorfgemeinschaft", "Versammlung", "Schützenfest",
                                "Erntedank", "Kirchenbuch", "Gemeinde", "Ortsgeschichte", "Fotografie", "Archiv", "Familie", "Hof", "Brief"]

    public static func line(_ i: Int) -> String {
        (0..<9).map { words[(i * 5 + $0 * 3) % words.count] }.joined(separator: " ")
    }

    /// Weiße Seite mit Textzeilen. `tiltCounterClockwise`: Drehung des Textes gegen den Uhrzeigersinn in Grad
    /// (ein nach rechts ansteigender Text hat einen positiven Wert).
    public static func textPage(width: Int = 1200, height: Int = 1600, tiltCounterClockwise: Double = 0, background: UInt8? = nil, pageScale: Double = 1, raggedEdges: Double = 0) -> CGImage {
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
            // Die Seite selbst ist weiß und kleiner als das Bild, bei Bedarf mit ausgefransten Rändern wie bei Zeitungsausschnitten.
            context.setFillColor(gray: 1, alpha: 1)
            if raggedEdges > 0 {
                context.addPath(raggedPath(rect: CGRect(x: 150, y: 150, width: width - 300, height: height - 300), amplitude: raggedEdges))
                context.fillPath()
            } else {
                context.fill(CGRect(x: 150, y: 150, width: width - 300, height: height - 300))
            }
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

    /// Rechteck mit ausgefransten Kanten: Zufallsweg entlang jeder Seite, bei festem Startwert reproduzierbar.
    static func raggedPath(rect: CGRect, amplitude: Double) -> CGPath {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31) * 2 - 1
        }
        func jitter(count: Int) -> [Double] {
            var walk = [Double](repeating: 0, count: count)
            var value = 0.0
            for i in 0..<count { value += next() * 0.8; value = max(-amplitude, min(amplitude, value)); walk[i] = value }
            return walk
        }
        let path = CGMutablePath()
        let stepsX = Int(rect.width / 6), stepsY = Int(rect.height / 6)
        let top = jitter(count: stepsX + 1), bottom = jitter(count: stepsX + 1)
        let left = jitter(count: stepsY + 1), right = jitter(count: stepsY + 1)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + left[0]))
        for i in 0...stepsX { path.addLine(to: CGPoint(x: rect.minX + rect.width * Double(i) / Double(stepsX), y: rect.minY + bottom[i])) }
        for i in 0...stepsY { path.addLine(to: CGPoint(x: rect.maxX + right[i], y: rect.minY + rect.height * Double(i) / Double(stepsY))) }
        for i in (0...stepsX).reversed() { path.addLine(to: CGPoint(x: rect.minX + rect.width * Double(i) / Double(stepsX), y: rect.maxY + top[i])) }
        for i in (0...stepsY).reversed() { path.addLine(to: CGPoint(x: rect.minX + left[i], y: rect.minY + rect.height * Double(i) / Double(stepsY))) }
        path.closeSubpath()
        return path
    }

    /// Bild aus zufälligem Rauschen.
    public static func noise(width: Int = 800, height: Int = 800) -> CGImage {
        var generator = SystemRandomNumberGenerator()
        var pixels = (0..<(width * height)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        }
        return context.makeImage()!
    }

    public static func blank(width: Int = 800, height: Int = 800, value: UInt8 = 255) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: CGFloat(value) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// PNG-Daten eines Bildes.
    public static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Ein Mock-Scanner, der immer dieses Bild als Aufnahme liefert.
    /// Mit `stillPreview` zeigt die Vorschau ein stehendes Bild statt eines flimmernden.
    /// Mit `appearsAfter` ist der Scanner erst nach so vielen Sekunden da, wie einer, den man später einschaltet.
    public static func scanner(delivering image: CGImage, stillPreview: Bool = false, appearsAfter: TimeInterval = 0,
                               scheduledUnplug: (after: TimeInterval, returnsAfter: TimeInterval)? = nil) -> MockScanner {
        let data = png(image)
        let size = ScanFormat(width: image.width, height: image.height)
        return MockScanner(
            formats: [size],
            imageProvider: { _ in MockImage(data: data, width: image.width, height: image.height) },
            stillPreview: stillPreview,
            appearsAfter: appearsAfter,
            scheduledUnplug: scheduledUnplug
        )
    }
}
