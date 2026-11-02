import Foundation
import Testing
@testable import ImagingKit

@Suite("Corrections")
struct CorrectionsTests {
    @Test func manualRotationOverridesAutomatic() {
        var c = Corrections(rotation: RotationCorrection(degrees: 2, enabled: false, source: .automatic, confidence: 0.3))
        #expect(c.needsReview)
        c.setRotation(degrees: 1.5)
        #expect(c.rotation.source == .manual)
        #expect(c.rotation.enabled)
        #expect(c.rotation.degrees == 1.5)
        #expect(c.rotation.confidence == nil)
        #expect(!c.needsReview)
        #expect(c.revision == 1)
    }

    @Test func lowConfidenceNeedsReview() {
        let c = Corrections(crop: CropCorrection(quad: .full, enabled: false, source: .automatic, confidence: 0.2))
        #expect(c.needsReview)
    }

    @Test func confidentAutomaticDoesNotNeedReview() {
        let c = Corrections(
            crop: CropCorrection(quad: .full, enabled: true, source: .automatic, confidence: 0.9),
            rotation: RotationCorrection(degrees: 1, enabled: true, source: .automatic, confidence: 0.9)
        )
        #expect(!c.needsReview)
    }

    @Test func noneNeedsNoReview() {
        #expect(!Corrections.none.needsReview)
    }

    @Test func togglesCountRevisionsAndMarkManual() {
        var c = Corrections()
        c.setEnabled(false)
        c.setCropEnabled(true)
        c.setRotationEnabled(true)
        #expect(c.revision == 3)
        #expect(!c.enabled)
        #expect(c.crop.source == .manual && c.rotation.source == .manual)
    }

    @Test func codableRoundTrip() throws {
        var c = Corrections()
        c.setCrop(Quad(topLeft: .init(x: 0.1, y: 0.2), topRight: .init(x: 0.9, y: 0.1), bottomRight: .init(x: 0.95, y: 0.9), bottomLeft: .init(x: 0.05, y: 0.85)))
        c.setRotation(degrees: -2.35)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Corrections.self, from: data) == c)
    }

    @Test func analyzerAppliesConfidentAndSuggestsUnsure() {
        let sure = Analysis(
            detection: DocumentDetection(quad: .full, reportedConfidence: 0.99, plausibility: 0.95),
            skew: SkewEstimate(degrees: 3, confidence: 0.9, contrast: 8), warnings: []
        )
        let applied = ImageAnalyzer.corrections(from: sure)
        #expect(applied.crop.enabled && applied.rotation.enabled)
        #expect(!applied.needsReview)

        let unsure = Analysis(
            detection: DocumentDetection(quad: .full, reportedConfidence: 0.99, plausibility: 0.95),
            skew: SkewEstimate(degrees: 3, confidence: 0.2, contrast: 2.5), warnings: ["unsicher"]
        )
        let suggested = ImageAnalyzer.corrections(from: unsure)
        #expect(suggested.crop.enabled)
        #expect(!suggested.rotation.enabled)
        #expect(suggested.rotation.degrees == 3)
        #expect(suggested.needsReview)
    }

    @Test func analyzerWithoutResultsDoesNothing() {
        let empty = ImageAnalyzer.corrections(from: Analysis(detection: nil, skew: nil, warnings: []))
        #expect(empty == Corrections())
    }

    @Test func plausibilityOfRectangleIsHigh() {
        let quad = Quad(topLeft: .init(x: 0.1, y: 0.1), topRight: .init(x: 0.9, y: 0.1), bottomRight: .init(x: 0.9, y: 0.9), bottomLeft: .init(x: 0.1, y: 0.9))
        #expect(DocumentDetector.plausibility(of: quad) > 0.95)
    }

    @Test func plausibilityOfTinyOrTwistedQuadIsLow() {
        let tiny = Quad(topLeft: .init(x: 0.4, y: 0.4), topRight: .init(x: 0.5, y: 0.4), bottomRight: .init(x: 0.5, y: 0.5), bottomLeft: .init(x: 0.4, y: 0.5))
        #expect(DocumentDetector.plausibility(of: tiny) == 0)
        let sheared = Quad(topLeft: .init(x: 0.1, y: 0.1), topRight: .init(x: 0.9, y: 0.1), bottomRight: .init(x: 0.5, y: 0.9), bottomLeft: .init(x: 0.1, y: 0.9))
        #expect(DocumentDetector.plausibility(of: sheared) < 0.5)
    }
}
