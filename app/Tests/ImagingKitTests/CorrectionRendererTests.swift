import CoreGraphics
import Testing
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
}
