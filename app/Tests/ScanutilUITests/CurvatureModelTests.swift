import ArchiveKit
import CoreGraphics
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

/// „Wölbung ausgleichen: alle Seiten“: misst, wo noch nicht gemessen ist, und schaltet ein, wo es sich lohnt.
@MainActor
@Suite("Wölbung: Modell")
struct CurvatureModelTests {
    private func makeModel() async -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-curve-\(UUID().uuidString)")
        let analysis = PageAnalysis(outerDetected: true, outerPlausibility: 0.9, gutterConfidence: 0.9, isSpread: true, warnings: [])
        var first = Corrections()
        first.crop = CropCorrection(quad: .full, enabled: false, source: .automatic, confidence: 0.9)
        let c = first
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: ArchiveStore(root: dir), thumbnailSize: 256,
                             analyze: { _ in AnalysisResult(corrections: c, warnings: [], analysis: analysis) },
                             analyzeBook: { _ in BookAnalysisResult(left: c, right: c, warnings: [], analysis: analysis) },
                             sound: SilentSound(), defaults: nil)
        await model.connect()
        return (model, dir)
    }

    private func waitForAnalysis(_ model: AppModel) async {
        for _ in 0..<160 {
            if model.series?.pages.allSatisfy({ $0.analysis != nil }) == true { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private var fanning: WarpField {
        var angles: [Float] = []
        for r in 0..<7 { for _ in 0..<3 { angles.append(Float(-0.4 * Double(r))) } }
        return WarpField(columns: 3, rows: 7, angles: angles)!
    }

    @Test func pagesWithoutAMeasurementNeedIt_andAfterwardsEveryPageHasOne() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan(); await waitForAnalysis(model)
        let id = try #require(model.series?.id)
        #expect(model.pagesNeedingCurvature(documentID: id) == 2)
        let changed = await model.equalizeCurvatureForAllPages(documentID: id)
        let document = try #require(model.latestDocument(id: id))
        #expect(document.pages.allSatisfy { $0.corrections.dewarp.wasMeasured }, "Gemessen, mit oder ohne Ergebnis")
        #expect(changed == 2)
        // Die künstliche Seite ist eben oder nicht messbar: Es lohnt sich nicht, also bleibt es aus, und es gibt nichts mehr zu tun.
        #expect(document.pages.allSatisfy { !$0.corrections.dewarp.enabled })
        #expect(model.pagesNeedingCurvature(documentID: id) == 0)
        let again = await model.equalizeCurvatureForAllPages(documentID: id)
        #expect(again == 0, "Ein zweiter Lauf ändert nichts")
        await model.disconnect()
    }

    @Test func aMeasuredPageThatIsWorthItGetsSwitchedOn_andOtherCorrectionsStay() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan(); await waitForAnalysis(model)
        let id = try #require(model.series?.id)
        let page = try #require(model.series?.pages.first)
        model.updatePage(documentID: id, pageID: page.id) {
            $0.dewarp = DewarpCorrection(enabled: false, source: .automatic, confidence: 1, field: self.fanning)
            $0.setRotation(degrees: 0.7)
        }
        #expect(model.pagesNeedingCurvature(documentID: id) == 2, "Eine gemessen aber aus, eine ungemessen")
        _ = await model.equalizeCurvatureForAllPages(documentID: id)
        let after = try #require(model.latestDocument(id: id)?.page(id: page.id))
        #expect(after.corrections.dewarp.enabled && after.corrections.dewarp.field == fanning)
        #expect(after.corrections.rotation.degrees == 0.7 && after.corrections.rotation.source == .manual, "Die Drehung von Hand bleibt")
        #expect(model.pagesNeedingCurvature(documentID: id) == 0)
        await model.disconnect()
    }

    @Test func aSeriesThatIsNotABookNeverNeedsIt() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Blätter")
        await model.scan()
        let id = try #require(model.series?.id)
        #expect(model.pagesNeedingCurvature(documentID: id) == 0)
        await model.disconnect()
    }
}
