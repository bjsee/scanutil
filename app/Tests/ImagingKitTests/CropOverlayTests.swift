import CoreGraphics
import Testing
@testable import ImagingKit

@Suite("Zuschnittsrahmen zeichnen")
struct CropOverlayTests {
    private func white(_ w: Int, _ h: Int) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()!
    }

    /// Rot, Grün, Blau des Pixels (x, y) mit Ursprung oben links.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    private let box = Quad(topLeft: .init(x: 0.25, y: 0.25), topRight: .init(x: 0.75, y: 0.25),
                           bottomRight: .init(x: 0.75, y: 0.75), bottomLeft: .init(x: 0.25, y: 0.75))

    @Test func theFrameKeepsTheInsideAndDarkensTheOutside() throws {
        let out = try #require(CropOverlay.draw([.init(quad: box, style: .used)], on: white(400, 400)))
        #expect(out.width == 400 && out.height == 400)
        #expect(pixel(out, 200, 200).r > 250, "Innen bleibt weiß")
        #expect(pixel(out, 20, 20).r < 170, "Außen ist abgedunkelt")
    }

    @Test func theFrameLinesSitWhereTheQuadIsWithTopLeftOrigin() throws {
        let out = try #require(CropOverlay.draw([.init(quad: box, style: .used)], on: white(400, 400)))
        let top = pixel(out, 200, 100)          // y = 0.25 · 400
        #expect(top.g > 180 && top.r < 100, "Grüne Linie oben: \(top)")
        #expect(pixel(out, 200, 300).g > 180, "Unten bei 0,75")
        #expect(pixel(out, 200, 150).g > 250 && pixel(out, 200, 150).r > 250, "Dazwischen nichts")
    }

    @Test func anUncertainFrameIsOrangeAndANeighbourDoesNotDarken() throws {
        let orange = try #require(CropOverlay.draw([.init(quad: box, style: .uncertain)], on: white(400, 400)))
        let p = pixel(orange, 200, 100)
        #expect(p.r > 200 && p.g > 100 && p.g < 200 && p.b < 100, "Orange: \(p)")
        let neighbour = try #require(CropOverlay.draw([.init(quad: box, style: .neighbour)], on: white(400, 400)))
        #expect(pixel(neighbour, 20, 20).r > 250, "Die Nachbarseite dunkelt nichts ab")
    }

    @Test func noFramesLeavesTheImageAlone() throws {
        let out = try #require(CropOverlay.draw([], on: white(50, 50)))
        #expect(pixel(out, 5, 5).r > 250)
    }
}
