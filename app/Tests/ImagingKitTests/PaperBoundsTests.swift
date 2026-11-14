import Testing
import CoreGraphics
import Foundation
@testable import ImagingKit

@Suite("Historisches Dokument: das ganze Papier finden")
struct PaperBoundsTests {
    /// 1000 × 800, schwarzer Untergrund, darauf Papier; `draw` zeichnet in Punkten von oben links.
    private func scene(paper: UInt8 = 200, _ draw: (CGContext, Int, Int) -> Void) -> CGImage {
        let w = 1000, h = 800
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 8.0 / 255, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(gray: CGFloat(paper) / 255, alpha: 1)
        draw(context, w, h)
        return context.makeImage()!
    }

    /// Rechteck in Punkten von oben links (x, y, Breite, Höhe).
    private func rect(_ c: CGContext, _ h: Int, _ x: Int, _ y: Int, _ w: Int, _ hh: Int) { c.fill(CGRect(x: x, y: h - y - hh, width: w, height: hh)) }

    @Test func theFrameCoversTheWholePaperPlusAThinBlackMargin() throws {
        let image = scene { c, _, h in rect(c, h, 200, 150, 600, 500) }                      // Papier x 200–800, y 150–650
        let quad = try #require(PaperBounds.detect(in: image))
        // Rand: 3 % von 600 = 18 Punkte in x, 3 % von 500 = 15 in y.
        #expect(abs(quad.topLeft.x - (200 - 18) / 1000.0) < 0.012 && abs(quad.topRight.x - (800 + 18) / 1000.0) < 0.012, "x \\(quad.topLeft.x)…\\(quad.topRight.x)")
        #expect(abs(quad.topLeft.y - (150 - 15) / 800.0) < 0.012 && abs(quad.bottomLeft.y - (650 + 15) / 800.0) < 0.012, "y \\(quad.topLeft.y)…\\(quad.bottomLeft.y)")
        #expect(quad.topLeft.x > 0 && quad.topRight.x < 1, "Mit schwarzem Rand, nicht bis an den Bildrand")
    }

    @Test func aTornCornerDoesNotMakeTheFrameSmaller() throws {
        let image = scene { c, _, h in
            rect(c, h, 200, 150, 600, 500)
            c.setFillColor(gray: 8.0 / 255, alpha: 1)                                           // Ecke unten links weggerissen
            c.move(to: CGPoint(x: 200, y: 150)); c.addLine(to: CGPoint(x: 330, y: 150)); c.addLine(to: CGPoint(x: 200, y: 280)); c.fillPath()
        }
        let quad = try #require(PaperBounds.detect(in: image))
        #expect(quad.topLeft.x < 0.2 && quad.topRight.x > 0.8 && quad.bottomLeft.y > 0.82, "Das Papier bleibt ganz im Rahmen")
    }

    @Test func aTiltedSheetIsFullyInsideTheFrame() throws {
        let image = scene { c, w, h in
            c.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2); c.rotate(by: 4 * .pi / 180)
            c.fill(CGRect(x: -280, y: -220, width: 560, height: 440))
        }
        let quad = try #require(PaperBounds.detect(in: image))
        // Eckpunkte des gedrehten Blatts (Mitte 500/400 in Punkten von unten; y spiegeln).
        let a = 4 * Double.pi / 180
        for (dx, dy) in [(-280.0, -220.0), (280, -220), (280, 220), (-280, 220)] {
            let x = 500 + dx * cos(a) - dy * sin(a), y = 400 - (dx * sin(a) + dy * cos(a))
            #expect(x / 1000 >= quad.topLeft.x - 0.002 && x / 1000 <= quad.topRight.x + 0.002 && y / 800 >= quad.topLeft.y - 0.002 && y / 800 <= quad.bottomLeft.y + 0.002,
                    "Ecke (\\(Int(x)), \\(Int(y))) liegt außerhalb")
        }
    }

    @Test func aHandAtTheEdgeIsNotCountedAsPaper() throws {
        // Papier x 200–700; ein heller Daumen ragt rechts bis x 900 heraus. Die Maske der Handerkennung deckt ihn ab.
        let image = scene { c, _, h in rect(c, h, 200, 150, 500, 500); rect(c, h, 700, 350, 200, 100) }
        let without = try #require(PaperBounds.detect(in: image))
        #expect(without.topRight.x > 0.9, "Ohne Maske zöge der Daumen den Rahmen auf")
        var cells = [UInt8](repeating: 0, count: 100 * 80)
        for y in 40..<47 { for x in 70..<91 { cells[y * 100 + x] = 255 } }                    // x 700–910, y 400–470 (Zellen zu 10 Punkten)
        for y in 35..<46 { for x in 70..<91 { cells[y * 100 + x] = 255 } }
        let hands = try #require(HandMask(width: 100, height: 80, cells: cells))
        let with = try #require(PaperBounds.detect(in: image, hands: hands))
        #expect(with.topRight.x < 0.75, "Mit Maske bleibt der Rahmen am Papier: \\(with.topRight.x)")
    }

    @Test func darkOldPaperIsFoundAndSpecksAndBlackImagesAreNot() throws {
        let dark = scene(paper: 70) { c, _, h in rect(c, h, 250, 100, 500, 600) }
        #expect(try #require(PaperBounds.detect(in: dark)).topLeft.x < 0.25, "Dunkles Papier ist heller als der Untergrund")
        let specks = scene { c, _, h in rect(c, h, 40, 40, 4, 4); rect(c, h, 900, 700, 3, 3); rect(c, h, 300, 200, 400, 400) }
        let quad = try #require(PaperBounds.detect(in: specks))
        #expect(quad.topLeft.x > 0.2 && quad.topRight.x < 0.8, "Staub zählt nicht: x \\(quad.topLeft.x)…\\(quad.topRight.x)")
        #expect(PaperBounds.detect(in: scene { _, _, _ in }) == nil, "Nur Untergrund: kein Papier")
    }

    @Test func aSheetFillingTheWholeImageGivesTheWholeImage() throws {
        let full = scene { c, w, h in c.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        let quad = try #require(PaperBounds.detect(in: full))
        #expect(quad.topLeft.x == 0 && quad.topLeft.y == 0 && quad.bottomRight.x == 1 && quad.bottomRight.y == 1)
    }
}
