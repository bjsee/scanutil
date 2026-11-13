import Testing
import CoreGraphics
import Foundation
@testable import ImagingKit

@Suite("Falz und Doppelseite")
struct BookAnalyzerTests {
    /// Künstliche Doppelseite: Papier mit Text auf dunklem Schreibtisch, dazu der Schatten im Falz.
    /// - Parameters:
    ///   - gutterX: Lage des Falzes in der Mitte, normiert.
    ///   - slope: Neigung des Falzes (x unten minus x oben), normiert.
    ///   - depth: Tiefe des Schattens in Grauwerten; 0 ergibt eine Doppelseite ohne Falz.
    private func spread(gutterX: Double = 0.5, slope: Double = 0, depth: Double = 150, text: Bool = true,
                        width: Int = 1600, height: Int = 1000) -> CGImage {
        var pixels = [UInt8](repeating: 70, count: width * height)
        for y in 0..<height {
            let xg = (gutterX + slope * (Double(y) / Double(height) - 0.5)) * Double(width)
            for x in 0..<width {
                let onPaper = x >= 40 && x < width - 40 && y >= 40 && y < height - 40
                guard onPaper else { continue }
                var value = 235.0
                let inLeftText = x >= 90 && x < width / 2 - 70, inRightText = x >= width / 2 + 70 && x < width - 90
                if text, (inLeftText || inRightText), y % 20 >= 7, y % 20 < 13, y > 90, y < height - 90,
                   (x / 37 + (y / 20) * 3) % 5 != 0 {
                    value = 40
                }
                if depth > 0 {
                    let d = (Double(x) - xg) / 25
                    value -= depth * exp(-d * d)
                }
                pixels[y * width + x] = UInt8(max(0, min(255, value)))
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func findsACenteredGutterDespiteText() throws {
        let gutter = try #require(GutterDetector.detect(in: spread()))
        #expect(abs(gutter.x(atY: 0.5) - 0.5) < 0.01)
        #expect(abs(gutter.slope) < 0.02)
        #expect(gutter.confidence > 0.6)
    }

    @Test func findsAnOffCenterGutter() throws {
        let gutter = try #require(GutterDetector.detect(in: spread(gutterX: 0.46)))
        #expect(abs(gutter.x(atY: 0.5) - 0.46) < 0.01)
    }

    @Test func findsATiltedGutter() throws {
        let gutter = try #require(GutterDetector.detect(in: spread(gutterX: 0.5, slope: 0.06)))
        #expect(abs(gutter.slope - 0.06) < 0.015)
        #expect(abs(gutter.x(atY: 0.5) - 0.5) < 0.01)
        #expect(gutter.confidence > 0.5)
    }

    @Test func noShadowMeansNoConfidentGutter() {
        let result = GutterDetector.detect(in: spread(depth: 0))
        #expect(result == nil || result!.confidence < Corrections.defaultConfidenceThreshold)
    }

    @Test func shallowShadowIsLessConfidentThanDeepOne() throws {
        let deep = try #require(GutterDetector.detect(in: spread(depth: 150)))
        let shallow = try #require(GutterDetector.detect(in: spread(depth: 22)))
        #expect(shallow.confidence < deep.confidence)
    }

    @Test func gutterOutsideTheSearchWindowIsNotFound() {
        // Falz bei 0.33 liegt knapp außerhalb des Fensters 0.35…0.65, seine Flanke ragt aber hinein:
        // am Fensterrand fällt das Profil nur ab, das ist eine Kante und kein Tal.
        let result = GutterDetector.detect(in: spread(gutterX: 0.33))
        #expect(result == nil || result!.confidence < Corrections.defaultConfidenceThreshold)
    }

    @Test func splitMeetsTheGutterOnTopAndBottomEdge() {
        let outer = Quad(topLeft: .init(x: 0.05, y: 0.05), topRight: .init(x: 0.95, y: 0.05),
                         bottomRight: .init(x: 0.95, y: 0.95), bottomLeft: .init(x: 0.05, y: 0.95))
        let gutter = Gutter(xTop: 0.48, xBottom: 0.54, confidence: 1)
        let (left, right) = BookAnalyzer.split(outer, at: gutter)
        #expect(abs(left.topRight.x - gutter.x(atY: left.topRight.y)) < 1e-9)
        #expect(abs(left.bottomRight.x - gutter.x(atY: left.bottomRight.y)) < 1e-9)
        #expect(left.topRight == right.topLeft && left.bottomRight == right.bottomLeft)
        #expect(left.topLeft == outer.topLeft && right.bottomRight == outer.bottomRight)
    }

    @Test func splitPagesTogetherCoverTheOuterArea() {
        func area(_ q: Quad) -> Double {
            let p = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft]
            var a = 0.0
            for i in 0..<4 { let u = p[i], v = p[(i + 1) % 4]; a += u.x * v.y - v.x * u.y }
            return abs(a) / 2
        }
        let outer = Quad(topLeft: .init(x: 0.04, y: 0.07), topRight: .init(x: 0.96, y: 0.03),
                         bottomRight: .init(x: 0.97, y: 0.93), bottomLeft: .init(x: 0.03, y: 0.96))
        let (left, right) = BookAnalyzer.split(outer, at: Gutter(xTop: 0.5, xBottom: 0.52, confidence: 1))
        #expect(abs(area(left) + area(right) - area(outer)) < 1e-9)
    }

    @Test func spreadPlausibilityRejectsPortraitDetections() {
        let portrait = Quad(topLeft: .init(x: 0.1, y: 0.05), topRight: .init(x: 0.5, y: 0.05),
                            bottomRight: .init(x: 0.5, y: 0.95), bottomLeft: .init(x: 0.1, y: 0.95))
        let landscape = Quad(topLeft: .init(x: 0.05, y: 0.1), topRight: .init(x: 0.95, y: 0.1),
                             bottomRight: .init(x: 0.95, y: 0.9), bottomLeft: .init(x: 0.05, y: 0.9))
        #expect(!BookAnalyzer.isPlausibleSpread(DocumentDetection(quad: portrait, reportedConfidence: 0.99, plausibility: 1)))
        #expect(BookAnalyzer.isPlausibleSpread(DocumentDetection(quad: landscape, reportedConfidence: 0.99, plausibility: 1)))
        #expect(!BookAnalyzer.isPlausibleSpread(DocumentDetection(quad: landscape, reportedConfidence: 0.99, plausibility: 0.3)))
    }

    @Test func analysisSplitsAtTheGutterAndNeverCrashesWithoutOuterEdge() throws {
        let analysis = BookAnalyzer.analyze(spread(gutterX: 0.47))
        let gutter = try #require(analysis.gutter)
        #expect(abs(gutter.x(atY: 0.5) - 0.47) < 0.015)
        // Gleich, ob Vision den Rand fand: die Seiten treffen sich am Falz.
        #expect(abs(analysis.leftQuad.topRight.x - gutter.x(atY: analysis.leftQuad.topRight.y)) < 0.02)
        #expect(analysis.leftQuad.topRight == analysis.rightQuad.topLeft)
    }

    @Test func aShallowGutterStillCropsBecauseThePositionIsRightEvenIfTheConfidenceIsLow() throws {
        // An einem echten Buch mit flacher Falzlinie (leere Seite, kaum Schatten) lag die Sicherheit bei 0,4 bis 0,5, die Lage stimmte.
        let analysis = BookAnalyzer.analyze(spread(depth: 13))
        let gutter = try #require(analysis.gutter)
        #expect(gutter.confidence < Corrections.defaultConfidenceThreshold, "Der Fall ist nur dann einer, wenn die Sicherheit niedrig ist: \(gutter.confidence)")
        let pages = BookAnalyzer.corrections(from: analysis)
        #expect(pages.left.crop.enabled && pages.right.crop.enabled, "Mit gefundenem Falz wird zugeschnitten")
        #expect(pages.left.crop.confidence != nil && pages.left.crop.confidence! < Corrections.defaultConfidenceThreshold, "Die niedrige Sicherheit bleibt sichtbar")
        #expect(analysis.warnings.contains { $0.contains("Falz ist unsicher") }, "Die Warnung bleibt: \(analysis.warnings)")
    }

    @Test func withoutAGutterNothingIsCroppedAutomatically() {
        let pages = BookAnalyzer.corrections(from: BookAnalyzer.analyze(spread(depth: 0)))
        #expect(!pages.left.crop.enabled && !pages.right.crop.enabled)
    }

    @Test func correctionsAreActiveOnlyWhenTheGutterIsConfident() throws {
        let sure = BookAnalyzer.corrections(from: BookAnalyzer.analyze(spread()))
        #expect(sure.left.crop.quad != nil && sure.right.crop.quad != nil)
        #expect(sure.left.crop.source == .automatic)

        let unsure = BookAnalyzer.corrections(from: BookAnalyzer.analyze(spread(depth: 0)))
        #expect(unsure.left.crop.enabled == false)
        #expect(unsure.left.needsReview)   // Vorschlag liegt vor, wurde aber nicht angewendet
    }

    @Test func everyPageCarriesAMeasurementAttemptSoItStaysQuietAfterwards() throws {
        let pages = BookAnalyzer.corrections(from: BookAnalyzer.analyze(spread()))
        #expect(pages.left.dewarp.wasMeasured && pages.right.dewarp.wasMeasured, "Eine Messung wurde versucht, mit oder ohne Ergebnis")
        // Der Zuschnitt auf das erkannte Viereck fächert die waagerechten Zeilen dieser künstlichen Seite um etwa 1° auf (das Viereck ist
        // nie ganz rechtwinklig zu den Zeilen). Die Messung sieht das, und das Ausgleichen stellt die Zeilen wieder gerade.
        #expect(pages.left.dewarp.hasField && pages.left.dewarp.enabled, "Aufgefächert und deshalb ausgeglichen")
    }
}
