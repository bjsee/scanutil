import CoreGraphics
import Testing
import ScannerKit
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

    /// Eine Seite, deren Zeilen sich über die Höhe auffächern: jedes Drittel aus einer eigenen Schräglage zusammengesetzt.
    /// Im oberen Drittel steht nur halb so viel Schrift (rechte Hälfte weiß), wie bei einer Seite mit Überschrift oder Bild.
    private func fannedPage(_ tilts: [Double], sparseTop: Bool = false) -> CGImage {
        let width = 1200, band = 533
        let context = CGContext(data: nil, width: width, height: band * 3, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: band * 3))
        for (i, tilt) in tilts.enumerated() {
            let page = SyntheticPage.textPage(width: width, height: 1600, tiltCounterClockwise: tilt)
            // Mittleres Drittel der Seite: dort ist die Schräglage rein. CGImage-Zeilen zählen von oben.
            guard let part = page.cropping(to: CGRect(x: 0, y: 533, width: width, height: band)) else { continue }
            // Das Bild steht oben, also ist Band 0 oben: y im Kontext zählt von unten.
            context.draw(part, in: CGRect(x: 0, y: (tilts.count - 1 - i) * band, width: width, height: band))
            if sparseTop, i == 0 {
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: width / 2, y: (tilts.count - 1 - i) * band, width: width / 2, height: band))
            }
        }
        return context.makeImage()!
    }

    @Test func averagedMeasurementEqualsTheNormalOneOnAFlatPage() throws {
        let page = SyntheticPage.textPage(tiltCounterClockwise: 1.5)
        let averaged = try #require(SkewEstimator.estimateAveraged(page))
        #expect(abs(averaged.degrees - 1.5) < 0.3, "gemittelt \(averaged.degrees)")
    }

    @Test func averagedMeasurementSplitsTheDifferenceOfAFanningPage() throws {
        let page = fannedPage([0, 1, 2], sparseTop: true)
        let whole = try #require(SkewEstimator.estimate(page))
        let averaged = try #require(SkewEstimator.estimateAveraged(page))
        #expect(abs(averaged.degrees - 1.0) < 0.3, "gemittelt \(averaged.degrees), ganze Seite \(whole.degrees)")
        #expect(abs(averaged.degrees - 1.0) < abs(whole.degrees - 1.0), "Der Mittelwert liegt näher an der Mitte als die Messung über die ganze Seite (\(whole.degrees))")
    }
}
