import CoreGraphics
import Foundation
import Testing
@testable import ImagingKit

@Suite("Papier aufhellen")
struct ToneTests {
    /// Ein Graubild aus einer Funktion (x, y) → Helligkeit 0…1.
    private func image(width: Int, height: Int, _ f: (Int, Int) -> Double) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let v = UInt8(max(0, min(255, (f(x, y) * 255).rounded())))
            let i = (y * width + x) * 4
            pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func value(_ image: CGImage, _ x: Int, _ y: Int) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Double(pixel[0]) / 255
    }

    /// Eine Seite: Helligkeitsverlauf 0,50 (links) bis 0,90 (rechts), Textzeilen in Dunkelgrau.
    private func shadedPage(textRows: Int = 14, darkBlock: Bool = false) -> CGImage {
        image(width: 600, height: 800) { x, y in
            if darkBlock, (150..<450).contains(x), (150..<450).contains(y) { return 0.14 }
            if y % 50 > 36, y % 50 < 42, y > 80, y < 80 + textRows * 50, x > 60, x < 540 { return 0.12 }
            return 0.50 + 0.40 * Double(x) / 600
        }
    }

    private func render(_ image: CGImage, tone: Bool) -> CGImage {
        var c = Corrections()
        c.tone = ToneCorrection(enabled: tone)
        return CorrectionRenderer.render(image, corrections: c)!
    }

    // MARK: Messung

    @Test func theBackgroundFieldFollowsTheShadingAndIgnoresText() throws {
        let w = 160, h = 200
        var lum = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let paper = 0.62 + 0.28 * Float(x) / Float(w)
            lum[y * w + x] = (y % 20 > 8 && y % 20 < 12 && x > 20 && x < 140) ? 0.1 : paper       // Schriftzeilen
        } }
        let field = try #require(ToneNormalizer.backgroundField(luminance: lum, width: w, height: h))
        let left = field[100 * w + 10], right = field[100 * w + 150]
        #expect(right > left + 0.15, "Der Verlauf steigt nach rechts wie das Papier: \(left) → \(right)")
        #expect(abs(field[100 * w + 80] - (0.62 + 0.28 * 0.5)) < 0.08, "In der Mitte ist es das Papier, nicht die Schrift: \(field[100 * w + 80])")
    }

    @Test func aTooDarkImageHasNothingToMeasure() {
        let lum = [Float](repeating: 0.08, count: 100 * 100)
        #expect(ToneNormalizer.backgroundField(luminance: lum, width: 100, height: 100) == nil)
        #expect(ToneNormalizer.backgroundField(luminance: [0.5, 0.5], width: 2, height: 1) == nil, "Zu klein")
    }

    @Test func largeDarkAreasDoNotPullTheFieldBelowTheFloor() throws {
        let w = 200, h = 200
        let lum = (0..<(w * h)).map { i -> Float in (i % w < 150 && i / w < 150) ? 0.1 : 0.9 }      // Dreiviertel-Zeichnung
        let field = try #require(ToneNormalizer.backgroundField(luminance: lum, width: w, height: h))
        #expect((field.min() ?? 0) >= ToneNormalizer.floorShare * 0.9 - 0.01, "Untergrenze: \(field.min() ?? 0)")
        #expect((field.max() ?? 0) <= 0.9 + 0.001)
    }

    // MARK: Wirkung auf das Bild

    @Test func paperBecomesEvenAndLightAcrossTheShading() {
        let out = render(shadedPage(), tone: true)
        // Papierstellen ohne Schrift: Zeilen 10 (zwischen den Textzeilen) an drei Orten über die Breite.
        let samples = [30, 300, 570].map { value(out, $0, 20) }
        #expect(samples.allSatisfy { $0 > 0.88 }, "Papier hell: \(samples)")
        #expect((samples.max() ?? 0) - (samples.min() ?? 1) < 0.08, "Papier gleichmäßig: \(samples)")
        let before = [30, 570].map { value(shadedPage(), $0, 20) }
        #expect(before[1] - before[0] > 0.2, "Vorher lag der Verlauf bei \(before)")
    }

    @Test func textStaysDark() {
        let out = render(shadedPage(), tone: true)
        #expect(value(out, 300, 140) < 0.25, "Schriftzeile bleibt dunkel: \(value(out, 300, 140))")
    }

    @Test func aLargeDarkDrawingIsNotBlownOut() {
        let out = render(shadedPage(darkBlock: true), tone: true)
        #expect(value(out, 300, 300) < 0.45, "Dunkle Fläche bleibt dunkel: \(value(out, 300, 300))")
        #expect(value(out, 560, 30) > 0.85, "Papier daneben ist hell: \(value(out, 560, 30))")
    }

    @Test func greyInkOnBrightPaperIsNotWhitenedAwayWhileTheDimSideBecomesBright() {
        // Links hell (0,90) mit grauer Schrift (0,55), rechts ein dunkler Schatten (0,50). Eine bloße Verstärkung um einen festen
        // Faktor, damit die dunkle Seite hell wird, würde die graue Schrift auf der hellen Seite zu Weiß machen.
        let page = image(width: 600, height: 800) { x, y in
            if x < 300 { return (y % 40 > 14 && y % 40 < 20 && x > 40) ? 0.55 : 0.90 }
            return 0.50
        }
        let out = render(page, tone: true)
        #expect(value(out, 150, 17) < 0.75, "Graue Schrift bleibt sichtbar: \(value(out, 150, 17))")
        #expect(value(out, 450, 400) > 0.85, "Der Schatten rechts wird hell: \(value(out, 450, 400))")
    }

    @Test func withoutTheSwitchThePixelsStayExactlyAsTheyWere() {
        let src = shadedPage()
        let out = render(src, tone: false)
        #expect(out.width == src.width && out.height == src.height)
        for (x, y) in [(10, 10), (300, 119), (590, 790)] { #expect(value(out, x, y) == value(src, x, y)) }
    }

    @Test func theSizeStaysTheSame() {
        let out = render(shadedPage(), tone: true)
        #expect(out.width == 600 && out.height == 800)
    }

    @Test func toneWorksAfterCropAndRotation() {
        var c = Corrections()
        c.tone = ToneCorrection(enabled: true)
        c.rotation = RotationCorrection(degrees: 3, enabled: true, source: .manual)
        let out = CorrectionRenderer.render(shadedPage(), corrections: c)!
        #expect(out.width < 600 && value(out, out.width / 2, 20) > 0.85)
    }

    // MARK: Einstellung

    @Test func oldFilesWithoutToneLoadWithToneOff() throws {
        let data = try JSONEncoder().encode(Corrections())
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["tone"] = nil
        let old = try JSONDecoder().decode(Corrections.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!old.tone.enabled)
    }

    @Test func switchingToneIsManualCountsARevisionAndChangesTheCacheKey() {
        var c = Corrections()
        let key = c.cacheKey
        c.setToneEnabled(true)
        #expect(c.tone.enabled && c.tone.source == .manual && c.revision == 1)
        #expect(c.cacheKey != key, "Das Vorschaubild muss neu berechnet werden")
    }

    @Test func theAutomaticAnalysisSwitchesToneOn() {
        let single = ImageAnalyzer.corrections(from: Analysis(detection: nil, skew: nil, warnings: []))
        #expect(single.tone.enabled && single.tone.source == .automatic)
    }
}
