import Testing
import CoreGraphics
import Foundation
@testable import ImagingKit

@Suite("Vierteldrehungen")
struct QuarterTurnTests {
    /// 60 × 40, dunkel, mit einem hellen Block (12 × 8) oben links und einem kleineren, grauen unten rechts als zweite Marke.
    private func marked() -> CGImage {
        let w = 60, h = 40
        var pixels = [UInt8](repeating: 20, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { pixels[(y * w + x) * 4 + 3] = 255 } }
        for y in 0..<8 { for x in 0..<12 { for c in 0..<3 { pixels[(y * w + x) * 4 + c] = 240 } } }              // oben links hell
        for y in (h - 4)..<h { for x in (w - 4)..<w { for c in 0..<3 { pixels[(y * w + x) * 4 + c] = 130 } } }   // unten rechts grau
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Wo der helle Block liegt: Mitte seiner hellen Punkte in Bildhälften (links/rechts, oben/unten).
    private func quadrant(of image: CGImage) -> (right: Bool, bottom: Bool) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<image.height { for x in 0..<image.width where data[(y * image.width + x) * 4] > 200 { sx += Double(x); sy += Double(y); n += 1 } }
        return (sx / n > Double(image.width) / 2, sy / n > Double(image.height) / 2)
    }

    @Test func eachQuarterTurnMovesTheCornerClockwiseAndSwapsTheSizeWhenOdd() throws {
        let image = marked()
        var c = Corrections(); c.enabled = true
        let expected: [(w: Int, h: Int, right: Bool, bottom: Bool)] = [
            (60, 40, false, false),     // 0: oben links
            (40, 60, true, false),      // 1 im Uhrzeigersinn: oben rechts
            (60, 40, true, true),       // 2: unten rechts
            (40, 60, false, true),      // 3: unten links
        ]
        for turns in 0..<4 {
            c.quarterTurns = turns
            let out = try #require(CorrectionRenderer.render(image, corrections: c))
            let q = quadrant(of: out), e = expected[turns]
            #expect(out.width == e.w && out.height == e.h, "\(turns) Vierteldrehungen: \(out.width)×\(out.height)")
            #expect(q.right == e.right && q.bottom == e.bottom, "\(turns) Vierteldrehungen: Block rechts \(q.right), unten \(q.bottom)")
        }
    }

    @Test func theTurnAlsoHoldsWhenTheCorrectionsAreSwitchedOff() throws {
        var c = Corrections(); c.enabled = false; c.quarterTurns = 1
        let out = try #require(CorrectionRenderer.render(marked(), corrections: c))
        #expect(out.width == 40 && out.height == 60, "Die Ausrichtung ist keine Korrektur und bleibt")
    }

    @Test func theTurnComesAfterTheCropSoTheCropFrameStaysInTheOriginal() throws {
        // Zuschnitt auf die linke Hälfte (30 × 40), dann gedreht: 40 × 30.
        var c = Corrections(); c.enabled = true
        c.crop = CropCorrection(quad: Quad(topLeft: .init(x: 0, y: 0), topRight: .init(x: 0.5, y: 0), bottomRight: .init(x: 0.5, y: 1), bottomLeft: .init(x: 0, y: 1)),
                                enabled: true, source: .manual)
        c.quarterTurns = 1
        let out = try #require(CorrectionRenderer.render(marked(), corrections: c))
        #expect(abs(out.width - 40) <= 1 && abs(out.height - 30) <= 1, "\(out.width)×\(out.height)")
    }

    @Test func turnByWrapsAroundAndNegativeTurnsGoCounterClockwise() {
        var c = Corrections()
        c.turn(by: -1)
        #expect(c.quarterTurns == 3)
        c.turn(by: 1); #expect(c.quarterTurns == 0)
        c.turn(by: 5); #expect(c.quarterTurns == 1)
        c.turn(by: 7); #expect(c.quarterTurns == 0)
        #expect(Corrections(quarterTurns: -3).quarterTurns == 1)
    }

    @Test func oldFilesWithoutTheFieldDecodeAsUpright_andTheKeyChanges() throws {
        var c = Corrections(); c.turn(by: 1)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Corrections.self, from: data).quarterTurns == 1)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "quarterTurns")
        #expect(try JSONDecoder().decode(Corrections.self, from: JSONSerialization.data(withJSONObject: object)).quarterTurns == 0)
        #expect(Corrections().cacheKey != c.cacheKey)
    }
}
