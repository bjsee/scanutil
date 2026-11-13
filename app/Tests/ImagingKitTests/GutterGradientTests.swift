import Testing
import CoreGraphics
import Foundation
@testable import ImagingKit

@Suite("Falz bei ungleichmäßigem Licht")
struct GutterGradientTests {
    /// Doppelseite mit flachem Falz und einem Helligkeitsverlauf: Das Papier ist in den unteren Bildzeilen links vom Falz (bei 0,38) dunkler als am Falz.
    private func spread(gradient: Double, depth: Double = 14, width: Int = 1000, height: Int = 700) -> CGImage {
        var pixels = [UInt8](repeating: 20, count: width * height)
        let gutter = 0.46 * Double(width)
        for y in 0..<height {
            let lower = Double(y) / Double(height)            // 0 oben, 1 unten
            for x in 100..<(width - 100) where y >= 60 && y < height - 60 {
                var value = 225.0
                value -= gradient * lower * max(0, 1 - abs(Double(x) - 0.38 * Double(width)) / (0.3 * Double(width)))   // dunkelste Stelle bei 0,38, unten stärker
                let d = (Double(x) - gutter) / 8
                value -= depth * exp(-d * d)
                pixels[y * width + x] = UInt8(max(0, min(255, value)))
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func aShallowGutterBeatsABrightnessGradientAcrossTheWindow() throws {
        let image = spread(gradient: 130)
        let gutter = try #require(GutterDetector.detect(in: image, xRange: 0.35...0.55, yRange: 0.1...0.9))
        #expect(abs(gutter.x(atY: 0.5) - 0.46) < 0.01, "Falz bei \(gutter.x(atY: 0.5))")
        #expect(abs(gutter.slope) < 0.02, "Neigung \(gutter.slope)")
    }
}
