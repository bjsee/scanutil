import CoreGraphics
import Testing
@testable import ImagingKit

@Suite("SkewEstimator")
struct SkewEstimatorTests {
    @Test(arguments: [-8.0, -3.0, 0.0, 2.0, 5.0, 12.0])
    func measuresKnownTilt(tilt: Double) throws {
        let estimate = try #require(SkewEstimator.estimate(SyntheticPage.textPage(tiltCounterClockwise: tilt)))
        // Ein nach rechts ansteigender Text (positiv) braucht eine Drehung im Uhrzeigersinn (positiv).
        #expect(abs(estimate.degrees - tilt) < 0.3, "gemessen \(estimate.degrees), erwartet \(tilt)")
        #expect(estimate.confidence >= Corrections.defaultConfidenceThreshold, "Sicherheit \(estimate.confidence)")
    }

    @Test func blankPageCannotBeMeasured() {
        #expect(SkewEstimator.estimate(SyntheticPage.blank()) == nil)
    }

    @Test func noiseHasLowConfidence() throws {
        if let estimate = SkewEstimator.estimate(SyntheticPage.noise()) {
            #expect(estimate.confidence < Corrections.defaultConfidenceThreshold, "Sicherheit \(estimate.confidence)")
        }
    }

    @Test func otsuSeparatesTwoLevels() {
        let pixels = [UInt8](repeating: 20, count: 100) + [UInt8](repeating: 230, count: 400)
        let threshold = SkewEstimator.otsuThreshold(pixels)
        #expect(threshold >= 20 && threshold < 230)
    }
}
