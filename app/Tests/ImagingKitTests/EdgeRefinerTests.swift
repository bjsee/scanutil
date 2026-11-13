import CoreGraphics
import Foundation
import Testing
@testable import ImagingKit

@Suite("Außenkanten nach innen rücken")
struct EdgeRefinerTests {
    private let cloth: (UInt8, UInt8, UInt8) = (10, 10, 12), paper: (UInt8, UInt8, UInt8) = (225, 222, 215)
    private let green: (UInt8, UInt8, UInt8) = (30, 120, 50), yellow: (UInt8, UInt8, UInt8) = (245, 215, 30)

    private struct Canvas {
        let width: Int, height: Int
        var pixels: [UInt8]
        init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8)) {
            self.width = width; self.height = height
            pixels = (0..<(width * height)).flatMap { _ in [fill.0, fill.1, fill.2, 255] }
        }
        mutating func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: (UInt8, UInt8, UInt8)) {
            for y in max(0, y0)..<min(height, y1) { for x in max(0, x0)..<min(width, x1) {
                let i = (y * width + x) * 4; pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2
            } }
        }
        func image() -> CGImage {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
    }

    /// 1000×700; Papier von (100, 60) bis (900, 640) auf Tuch, mit etwas Schrift in der Mitte.
    private func scene(strip: Bool = false) -> Canvas {
        var c = Canvas(width: 1000, height: 700, fill: cloth)
        if strip { c.rect(72, 60, 100, 640, green) }
        c.rect(100, 60, 900, 640, paper)
        for row in 0..<10 { c.rect(200, 150 + row * 40, 800, 158 + row * 40, (30, 30, 30)) }
        return c
    }

    private func quad(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> Quad {
        Quad(topLeft: .init(x: l / 1000, y: t / 700), topRight: .init(x: r / 1000, y: t / 700),
             bottomRight: .init(x: r / 1000, y: b / 700), bottomLeft: .init(x: l / 1000, y: b / 700))
    }

    @Test func aGreenCoverStripAtTheLeftEdgeIsMovedOut() {
        let refined = EdgeRefiner.refine(quad(72, 60, 900, 640), in: scene(strip: true).image())
        #expect(refined.topLeft.x * 1000 >= 98 && refined.topLeft.x * 1000 <= 106, "Linke Kante bei \(refined.topLeft.x * 1000)")
        #expect(refined.bottomLeft.x * 1000 >= 98)
        #expect(abs(refined.topRight.x * 1000 - 900) < 3, "Die rechte Kante bleibt")
    }

    @Test func aQuadThatAlreadySitsOnThePaperIsLeftAlone() {
        let original = quad(100, 60, 900, 640)
        let refined = EdgeRefiner.refine(original, in: scene().image())
        for (a, b) in [(original.topLeft, refined.topLeft), (original.topRight, refined.topRight),
                       (original.bottomRight, refined.bottomRight), (original.bottomLeft, refined.bottomLeft)] {
            #expect(abs(a.x - b.x) * 1000 < 2 && abs(a.y - b.y) * 700 < 2, "Ecke bewegt: \(a) → \(b)")
        }
    }

    @Test func darkClothAroundTheQuadIsCutOffOnAllSides() {
        let refined = EdgeRefiner.refine(quad(80, 40, 920, 660), in: scene().image())
        #expect(refined.topLeft.x * 1000 > 96 && refined.topRight.x * 1000 < 904)
        #expect(refined.topLeft.y * 700 > 56 && refined.bottomLeft.y * 700 < 644)
    }

    @Test func aMarkerOverPartOfTheEdgeDoesNotHoldItBack() {
        var c = scene(strip: true)
        c.rect(40, 250, 140, 420, yellow)        // der Marker liegt über dem Einbandstreifen und etwas Papier
        let refined = EdgeRefiner.refine(quad(72, 60, 900, 640), in: c.image())
        #expect(refined.topLeft.x * 1000 >= 98, "Trotz Marker bei \(refined.topLeft.x * 1000)")
    }

    @Test func anEdgeThatWouldHaveToMoveTooFarIsLeftAlone() {
        // Das Viereck ist viel zu groß (90 Pixel Tuch ringsum, erlaubt sind 5 %, hier etwa 40 bis 49): Dann stimmt etwas anderes
        // nicht, und die Kante bleibt, wo sie ist, statt blind zu wandern.
        let big = quad(10, 10, 990, 690)
        let refined = EdgeRefiner.refine(big, in: scene().image())
        #expect(abs(refined.topLeft.x - big.topLeft.x) * 1000 < 2 && abs(refined.topLeft.y - big.topLeft.y) * 700 < 2)
        // Ein mäßig zu großes (30 Pixel Tuch) wird dagegen korrigiert.
        let near = EdgeRefiner.refine(quad(70, 30, 930, 670), in: scene().image())
        #expect(near.topLeft.x * 1000 > 96 && near.topLeft.y * 700 > 56, "Eckpunkt: \(near.topLeft.x * 1000), \(near.topLeft.y * 700)")
    }

    @Test func textAtThePageEdgeIsNotCutOff() {
        var c = scene()
        for row in 0..<10 { c.rect(104, 150 + row * 40, 800, 158 + row * 40, (30, 30, 30)) }   // Zeilen bis 4 Pixel an die Papierkante
        let refined = EdgeRefiner.refine(quad(100, 60, 900, 640), in: c.image())
        #expect(refined.topLeft.x * 1000 < 108, "Die Kante frisst die Zeilen: \(refined.topLeft.x * 1000)")
    }

    @Test func aDarkImageHasNothingToMeasureAndStaysAsItIs() {
        let dark = Canvas(width: 400, height: 300, fill: (12, 12, 12)).image()
        let original = quad(100, 60, 900, 640)
        #expect(EdgeRefiner.refine(original, in: dark) == original)
    }
}
