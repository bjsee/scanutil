import Testing
import CoreGraphics
import Foundation
import ScannerKit
@testable import ImagingKit

@Suite("Wölbung ausgleichen")
struct DewarpTests {
    /// Ein Raster, dessen Zeilenwinkel nur von der Höhe abhängen: oben `top`, unten `bottom`, dazwischen linear.
    private func verticalField(top: Double, bottom: Double, columns: Int = 3, rows: Int = 7) -> WarpField {
        var angles: [Float] = []
        for r in 0..<rows { for _ in 0..<columns { angles.append(Float(top + (bottom - top) * Double(r) / Double(rows - 1))) } }
        return WarpField(columns: columns, rows: rows, angles: angles)!
    }

    /// Eine ebene Textseite, durch den Renderer so verformt, dass die Zeilen oben bei `top` und unten bei `bottom` Grad laufen.
    /// (Das Anwenden eines Rasters mit umgekehrtem Vorzeichen und Bezugswinkel 0 dreht die Zeilen um das Raster selbst.)
    private func fannedPage(top: Double, bottom: Double) throws -> CGImage {
        let flat = SyntheticPage.textPage(width: 1000, height: 1400)
        let inverse = verticalField(top: -top, bottom: -bottom)
        return try #require(DewarpRenderer.apply(to: flat, field: inverse, reference: 0))
    }

    private func gray(_ image: CGImage) throws -> GrayBitmap { try #require(GrayBitmap(image, maxDimension: 1000)) }

    // MARK: Raster

    @Test func fieldRejectsWrongSizes() {
        #expect(WarpField(columns: 3, rows: 2, angles: [0, 1, 2]) == nil)
        #expect(WarpField(columns: 0, rows: 2, angles: []) == nil)
        #expect(WarpField(columns: 2, rows: 2, angles: [0, 0, 0, 0]) != nil)
    }

    @Test func fieldInterpolatesBilinearlyBetweenCellCenters() throws {
        let field = try #require(WarpField(columns: 2, rows: 2, angles: [0, 2, 4, 6]))
        let cx0 = WarpField.center(column: 0, of: 2), cx1 = WarpField.center(column: 1, of: 2)
        let cy0 = WarpField.center(row: 0, of: 2), cy1 = WarpField.center(row: 1, of: 2)
        #expect(abs(field.angle(atX: cx0, y: cy0) - 0) < 1e-9)
        #expect(abs(field.angle(atX: cx1, y: cy1) - 6) < 1e-9)
        #expect(abs(field.angle(atX: (cx0 + cx1) / 2, y: (cy0 + cy1) / 2) - 3) < 1e-9, "Mitte aller vier Zellen: Mittelwert")
        #expect(abs(field.angle(atX: 0, y: 0) - 0) < 1e-9, "Außerhalb der äußersten Mitte gilt deren Wert")
        #expect(abs(field.angle(atX: 1, y: 1) - 6) < 1e-9)
        #expect(abs(field.mean - 3) < 1e-9 && abs(field.spread - 6) < 1e-9)
    }

    // MARK: Messung

    @Test func recoversAFanningPageAndAnEvenPageHasNoSpread() throws {
        let fanned = try fannedPage(top: 0, bottom: -2.0)
        let estimate = try #require(DewarpEstimator.estimate(fanned))
        #expect(estimate.reliableShare >= 0.7, "verlässlich \(estimate.reliableShare)")
        let topRow = Double(estimate.field.angles[0 * 3 + 1]), bottomRow = Double(estimate.field.angles[6 * 3 + 1])
        #expect(abs(topRow - 0) < 0.4 && abs(bottomRow - (-2.0)) < 0.4, "oben \(topRow), unten \(bottomRow)")
        #expect(estimate.worthApplying)

        let even = try #require(DewarpEstimator.estimate(SyntheticPage.textPage(width: 1000, height: 1400, tiltCounterClockwise: 1.2)))
        #expect(even.field.spread < DewarpEstimator.minimumSpread, "Eine ebene, nur schräge Seite hat keine Spanne: \(even.field.spread)")
        #expect(!even.worthApplying)
    }

    @Test func aBlankPageCannotBeMeasured() {
        #expect(DewarpEstimator.estimate(SyntheticPage.blank()) == nil)
    }

    // MARK: Ausgleichen

    @Test func equalizingRemovesTheSpread() throws {
        let fanned = try fannedPage(top: 0, bottom: -2.4)
        let estimate = try #require(DewarpEstimator.estimate(fanned))
        let straightened = try #require(DewarpRenderer.apply(to: fanned, field: estimate.field, reference: estimate.field.mean))
        let after = try #require(DewarpEstimator.estimate(straightened))
        #expect(after.field.spread < 0.8, "Spanne nachher \(after.field.spread), vorher \(estimate.field.spread)")
        #expect(after.field.spread < estimate.field.spread / 2)
        #expect(straightened.width == fanned.width && straightened.height == fanned.height)
    }

    @Test func aFieldEqualToTheReferenceLeavesThePageAlone() throws {
        let flat = SyntheticPage.textPage(width: 600, height: 800)
        let field = try #require(WarpField(columns: 3, rows: 7, angles: [Float](repeating: 1.0, count: 21)))
        let same = try #require(DewarpRenderer.apply(to: flat, field: field, reference: 1.0))
        let a = try gray(flat), b = try gray(same)
        var different = 0
        for i in a.pixels.indices where abs(Int(a.pixels[i]) - Int(b.pixels[i])) > 2 { different += 1 }
        #expect(Double(different) / Double(a.pixels.count) < 0.002, "\(different) Bildpunkte weichen ab")
    }

    // MARK: Korrekturen

    @Test func correctionsCarryTheFieldThroughJSONAndOldFilesHaveNone() throws {
        var c = Corrections()
        c.dewarp = DewarpCorrection(enabled: true, source: .automatic, confidence: 0.9, field: verticalField(top: 0, bottom: -1.5))
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Corrections.self, from: data) == c)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "dewarp")
        let old = try JSONDecoder().decode(Corrections.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.dewarp == DewarpCorrection() && !old.dewarp.enabled)
    }

    @Test func switchingItByHandMarksItManualAndChangesTheKey() {
        var c = Corrections()
        c.dewarp = DewarpCorrection(enabled: false, source: .automatic, confidence: 0.9, field: verticalField(top: 0, bottom: -1.5))
        let before = c.cacheKey
        c.setDewarpEnabled(true)
        #expect(c.dewarp.enabled && c.dewarp.source == .manual)
        #expect(c.cacheKey != before)
    }

    @Test func theRendererStraightensTheLinesWhenEnabled() throws {
        let fanned = try fannedPage(top: 0, bottom: -2.4)
        let estimate = try #require(DewarpEstimator.estimate(fanned))
        var c = Corrections()
        c.rotation = RotationCorrection(degrees: estimate.field.mean, enabled: true, source: .automatic, confidence: 1)
        c.dewarp = DewarpCorrection(enabled: false, source: .automatic, confidence: 1, field: estimate.field)
        let without = try #require(CorrectionRenderer.render(fanned, corrections: c))
        c.dewarp.enabled = true
        let with = try #require(CorrectionRenderer.render(fanned, corrections: c))
        let spreadWithout = try #require(DewarpEstimator.estimate(without)).field.spread
        let spreadWith = try #require(DewarpEstimator.estimate(with)).field.spread
        #expect(spreadWith < spreadWithout / 2, "Spanne mit \(spreadWith), ohne \(spreadWithout)")
    }

    // MARK: Bewertung

    @Test func gatingNeedsAnEvenSpreadAndNoWildDeviations() throws {
        let tame = DewarpEstimate(field: verticalField(top: 0, bottom: -2), reliableShare: 1)
        #expect(tame.worthApplying)
        #expect(!DewarpEstimate(field: verticalField(top: 0, bottom: -2), reliableShare: 0.5).worthApplying, "zu wenige verlässliche Fenster")
        #expect(!DewarpEstimate(field: verticalField(top: 0, bottom: -0.2), reliableShare: 1).worthApplying, "kaum Spanne")
        #expect(!DewarpEstimate(field: verticalField(top: 0, bottom: -20), reliableShare: 1).worthApplying, "Fehlmessung statt Wölbung")
    }
}
