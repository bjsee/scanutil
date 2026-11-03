import ArchiveKit
import CoreGraphics
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

@MainActor
@Suite("Handentfernung im Modell")
struct HandRemovalModelTests {
    /// Eine feste Analyse, die Hände gefunden hat.
    nonisolated private static let withHands: @Sendable (CGImage) -> AnalysisResult = { image in
        let analysis = ImageAnalyzer.analyze(image)
        return AnalysisResult(corrections: ImageAnalyzer.corrections(from: analysis), warnings: analysis.warnings)
    }

    private func makeModel(book: Bool = false) async -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-hands-\(UUID().uuidString)")
        let image = SyntheticPage.pageWithThumb()
        let model = AppModel(scanner: SyntheticPage.scanner(delivering: image), store: ArchiveStore(root: dir), thumbnailSize: 800,
                             analyze: Self.withHands, analyzeBook: { img in
            let analysis = BookAnalyzer.analyze(img), pages = BookAnalyzer.corrections(from: analysis)
            return BookAnalysisResult(left: pages.left, right: pages.right, warnings: analysis.warnings)
        })
        await model.connect()
        return (model, dir)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    @Test func aScanWithAThumbGetsAHandRemovalCorrectionThatCanBeSwitchedOffAndOn() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.scan()
        let id = try #require(model.scans.first?.id)
        #expect(await eventually { model.scans.first?.corrections.handRemoval.hasMask == true }, "Der Daumen wurde nicht erkannt")
        #expect(model.scans.first?.corrections.handRemoval.enabled == true, "Sicher erkannt: wird angewendet")

        model.setHandRemovalEnabled(id: id, false)
        let off = try #require(model.scans.first?.corrections.handRemoval)
        #expect(!off.enabled && off.source == .manual && off.hasMask)
        // Gespeichert
        let saved = try #require(try ArchiveStore(root: model.archiveURL).corrections(for: id))
        #expect(!saved.handRemoval.enabled && saved.handRemoval.hasMask)

        model.setHandRemovalEnabled(id: id, true)
        #expect(model.scans.first?.corrections.handRemoval.enabled == true)
        await model.disconnect()
    }

    @Test func theDisplayedScanChangesWhenHandsAreRemoved() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.scan()
        let id = try #require(model.scans.first?.id)
        #expect(await eventually { model.scans.first?.corrections.handRemoval.enabled == true && model.scans.first?.corrected != nil })
        let with = model.scans.first?.corrected
        model.setHandRemovalEnabled(id: id, false)
        #expect(await eventually { model.scans.first?.corrected != nil && model.scans.first?.corrected !== with })
        await model.disconnect()
    }

    @Test func bookPagesCarryTheMaskAndSwitchIndependently() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let scanID = try #require(model.scans.first?.id)
        #expect(await eventually { model.pages(of: scanID).allSatisfy { $0.corrections.handRemoval.hasMask } }, "Die Seiten tragen keine Maske")
        let pages = model.pages(of: scanID)
        model.setPageHandRemovalEnabled(pageID: pages[0].id, false)
        #expect(model.pages(of: scanID)[0].corrections.handRemoval.enabled == false)
        #expect(model.pages(of: scanID)[1].corrections.handRemoval.enabled == true, "Die andere Seite bleibt")
        let saved = try ArchiveStore(root: model.archiveURL).loadDocument(id: try #require(model.series?.id))
        #expect(saved.pages[0].corrections.handRemoval.enabled == false && saved.pages[1].corrections.handRemoval.enabled == true)
        await model.disconnect()
    }

    @Test func aScanWithoutHandsHasNothingToSwitch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-hands-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = SyntheticPage.textPage(width: 1600, height: 1600, tiltCounterClockwise: 6, background: 10, raggedEdges: 30)
        let model = AppModel(scanner: SyntheticPage.scanner(delivering: page), store: ArchiveStore(root: dir), thumbnailSize: 800, analyze: Self.withHands)
        await model.connect()
        await model.scan()
        try await Task.sleep(for: .seconds(2))
        #expect(model.scans.first?.corrections.handRemoval.hasMask == false)
        await model.disconnect()
    }
}
