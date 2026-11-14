import Testing
import CoreGraphics
import Foundation
@testable import ImagingKit

@Suite("Zwei Teilbilder nebeneinander")
struct PageJoinerTests {
    private func solid(_ w: Int, _ h: Int, _ gray: UInt8) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { pixels[i * 4] = gray; pixels[i * 4 + 1] = gray; pixels[i * 4 + 2] = gray; pixels[i * 4 + 3] = 255 }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(pixels) as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func gray(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Int(data[(y * image.width + x) * 4])
    }

    @Test func theSecondPartLiesRightOfTheFirstWithoutGapByDefault() throws {
        let out = try #require(PageJoiner.compose(first: solid(100, 60, 50), second: solid(80, 70, 200)))
        #expect(out.width == 180 && out.height == 70, "\(out.width)×\(out.height)")
        #expect(gray(out, 10, 10) == 50 && gray(out, 99, 59) == 50, "Links der erste Teil")
        #expect(gray(out, 100, 10) == 200 && gray(out, 179, 69) == 200, "Rechts der zweite Teil, direkt anschließend")
        #expect(gray(out, 50, 65) == 255, "Unter dem kürzeren ersten Teil ist freier Raum, weiß")
    }

    @Test func aPositiveGapOpensASpaceAndANegativeOneOverlaps() throws {
        let first = solid(100, 60, 50), second = solid(80, 60, 200)
        let open = try #require(PageJoiner.compose(first: first, second: second, gap: 0.1))
        #expect(open.width == 190, "10 % von 100 Punkten Abstand")
        #expect(gray(open, 105, 30) == 255 && gray(open, 110, 30) == 200, "Im Abstand ist es weiß")
        let overlap = try #require(PageJoiner.compose(first: first, second: second, gap: -0.1))
        #expect(overlap.width == 170, "10 Punkte Überlappung")
        #expect(gray(overlap, 89, 30) == 50 && gray(overlap, 90, 30) == 200, "Der zweite liegt über dem ersten")
    }

    @Test func theShiftMovesTheSecondPartDownOrUp() throws {
        let first = solid(100, 60, 50), second = solid(80, 60, 200)
        let down = try #require(PageJoiner.compose(first: first, second: second, shift: 0.1))
        #expect(down.height == 66, "Um 10 % von 60 Punkten nach unten")
        #expect(gray(down, 110, 2) == 255 && gray(down, 110, 7) == 200, "Oben rechts bleibt ein freier Streifen")
        #expect(gray(down, 10, 2) == 50)
        let up = try #require(PageJoiner.compose(first: first, second: second, shift: -0.1))
        #expect(up.height == 66)
        #expect(gray(up, 10, 2) == 255 && gray(up, 10, 7) == 50, "Nach oben verschoben heißt: Der erste Teil rückt nach unten")
        #expect(gray(up, 110, 2) == 200)
    }

    @Test func anOverlapNeverHidesTheWholeSecondPart() throws {
        let out = try #require(PageJoiner.compose(first: solid(100, 60, 50), second: solid(20, 60, 200), gap: -5))
        // Der zweite Teil rutscht höchstens so weit nach links, dass noch ein Punkt von ihm im Bild liegt (ganz links), und das Bild
        // wird nicht schmaler als der erste Teil.
        #expect(out.width == 100 && gray(out, 0, 30) == 200 && gray(out, 50, 30) == 50, "Ein Rest des zweiten bleibt sichtbar")
    }
}
