import CoreGraphics
import Testing
import ScannerKit
@testable import ImagingKit

@Suite("CorrectionRenderer")
struct CorrectionRendererTests {
    @Test func disabledReturnsOriginalSize() throws {
        let image = SyntheticPage.textPage()
        var corrections = Corrections(rotation: RotationCorrection(degrees: 5, enabled: true))
        corrections.enabled = false
        let result = try #require(CorrectionRenderer.render(image, corrections: corrections))
        #expect(result.width == image.width && result.height == image.height)
    }

    @Test func noCorrectionsKeepsSize() throws {
        let image = SyntheticPage.textPage()
        let result = try #require(CorrectionRenderer.render(image, corrections: .none))
        #expect(result.width == image.width && result.height == image.height)
    }

    @Test func rotationLevelsTiltedText() throws {
        // Der Ende-zu-Ende-Test für das Vorzeichen: gemessen, angewendet, erneut gemessen.
        let tilted = SyntheticPage.textPage(tiltCounterClockwise: 6)
        let estimate = try #require(SkewEstimator.estimate(tilted))
        let corrections = Corrections(rotation: RotationCorrection(degrees: estimate.degrees, enabled: true, source: .automatic, confidence: estimate.confidence))
        let levelled = try #require(CorrectionRenderer.render(tilted, corrections: corrections))
        let after = try #require(SkewEstimator.estimate(levelled))
        #expect(abs(after.degrees) < 0.4, "Restwinkel \(after.degrees)")
    }

    @Test func rotationCropsToInscribedRectangle() throws {
        let image = SyntheticPage.textPage()
        let corrections = Corrections(rotation: RotationCorrection(degrees: 10, enabled: true))
        let result = try #require(CorrectionRenderer.render(image, corrections: corrections))
        #expect(result.width < image.width && result.height < image.height)
        #expect(result.width > image.width / 2)
    }

    @Test func fullQuadCropKeepsRoughSize() throws {
        let image = SyntheticPage.textPage()
        let corrections = Corrections(crop: CropCorrection(quad: .full, enabled: true))
        let result = try #require(CorrectionRenderer.render(image, corrections: corrections))
        #expect(abs(result.width - image.width) <= 2)
        #expect(abs(result.height - image.height) <= 2)
    }

    @Test func cropReducesToQuadSize() throws {
        let image = SyntheticPage.textPage()
        let quad = Quad(topLeft: .init(x: 0.25, y: 0.25), topRight: .init(x: 0.75, y: 0.25),
                        bottomRight: .init(x: 0.75, y: 0.75), bottomLeft: .init(x: 0.25, y: 0.75))
        let result = try #require(CorrectionRenderer.render(image, corrections: Corrections(crop: CropCorrection(quad: quad, enabled: true))))
        #expect(abs(result.width - image.width / 2) <= 4)
        #expect(abs(result.height - image.height / 2) <= 4)
    }

    @Test func inscribedRectOfSquareAtFortyFiveDegrees() {
        let size = CorrectionRenderer.largestInscribedRect(width: 100, height: 100, angle: .pi / 4)
        #expect(abs(size.width - 70.71) < 0.1)
    }

    @Test func inscribedRectWithoutRotationIsFullSize() {
        let size = CorrectionRenderer.largestInscribedRect(width: 300, height: 200, angle: 0)
        #expect(size.width == 300 && size.height == 200)
    }

    /// Liest die Pixel in den Ecken und in der Mitte aus: nach Drehung und Beschnitt darf nichts leer oder transparent sein.
    private func cornerPixels(_ image: CGImage) -> [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let points = [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3), (w / 2, h / 2)]
        return points.map { x, y in let i = (y * w + x) * 4; return (data[i], data[i + 1], data[i + 2], data[i + 3]) }
    }

    @Test(arguments: [-12.0, -3.0, 3.0, 8.0, 12.0])
    func rotationLeavesNoEmptyCorners(degrees: Double) throws {
        // Eine ganz weiße Seite: jedes nicht weiße oder transparente Pixel stammt aus dem Rand der Drehung.
        let white = SyntheticPage.blank(width: 1200, height: 900, value: 255)
        let corrections = Corrections(rotation: RotationCorrection(degrees: degrees, enabled: true))
        let result = try #require(CorrectionRenderer.render(white, corrections: corrections))
        for (index, pixel) in cornerPixels(result).enumerated() {
            #expect(pixel.a == 255 && pixel.r == 255 && pixel.g == 255 && pixel.b == 255, "Pixel \(index) bei \(degrees)°: \(pixel)")
        }
    }

    @Test func croppedAndRotatedLeavesNoEmptyCorners() throws {
        let white = SyntheticPage.blank(width: 1200, height: 900, value: 255)
        let quad = Quad(topLeft: .init(x: 0.1, y: 0.1), topRight: .init(x: 0.9, y: 0.1), bottomRight: .init(x: 0.9, y: 0.9), bottomLeft: .init(x: 0.1, y: 0.9))
        let corrections = Corrections(crop: CropCorrection(quad: quad, enabled: true), rotation: RotationCorrection(degrees: 7, enabled: true))
        let result = try #require(CorrectionRenderer.render(white, corrections: corrections))
        for (index, pixel) in cornerPixels(result).enumerated() {
            #expect(pixel.a == 255 && pixel.r == 255, "Pixel \(index): \(pixel)")
        }
    }
}
