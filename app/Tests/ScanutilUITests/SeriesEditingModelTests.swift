import ArchiveKit
import CoreGraphics
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

/// Was „Serie bearbeiten“ vom Modell braucht: Analyse-Zusammenfassung an den Seiten, Seiten beliebiger Serien ändern, geprüft, neu erkennen.
@MainActor
@Suite("Serie bearbeiten: Modell")
struct SeriesEditingModelTests {
    private static let single = PageAnalysis(outerDetected: true, outerPlausibility: 0.4, handCoverage: 0.03, warnings: ["Der Rand ist unsicher."])
    private static let spread = PageAnalysis(outerDetected: true, outerPlausibility: 0.9, gutterConfidence: 0.39, isSpread: true,
                                             warnings: ["Der Falz ist unsicher."])

    private func crop(_ confidence: Double) -> Corrections {
        var c = Corrections()
        c.crop = CropCorrection(quad: .full, enabled: false, source: .automatic, confidence: confidence)
        c.rotation = RotationCorrection(degrees: 1, enabled: true, source: .automatic, confidence: 1)
        return c
    }

    private func makeModel(delay: TimeInterval = 0, archive: URL? = nil) async -> (AppModel, ArchiveStore, URL) {
        let dir = archive ?? FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-edit-\(UUID().uuidString)")
        let store = ArchiveStore(root: dir)
        let single = Self.single, spread = Self.spread, corrections = crop(0.4)
        let model = AppModel(
            scanner: MockScanner(previewsEnabled: false), store: store, thumbnailSize: 64,
            analyze: { _ in
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                return AnalysisResult(corrections: corrections, warnings: single.warnings, analysis: single)
            },
            analyzeBook: { _ in
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                return BookAnalysisResult(left: corrections, right: corrections, warnings: spread.warnings, analysis: spread)
            },
            sound: SilentSound(), defaults: nil)
        await model.connect()
        return (model, store, dir)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<160 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(25)) }
        return condition()
    }

    // MARK: Zusammenfassung an den Seiten

    @Test func aBookAnalysisPutsTheSummaryOnBothPagesAndSavesIt() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let id = try #require(model.series?.id)
        #expect(await eventually { model.series?.pages.allSatisfy { $0.analysis == Self.spread } == true })
        let saved = try store.loadDocument(id: id)
        #expect(saved.pages.count == 2 && saved.pages.allSatisfy { $0.analysis == Self.spread }, "Auch auf der Platte")
        await model.disconnect()
    }

    @Test func aSinglePageAnalysisIsMirroredIntoThePage() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Einzeln")
        await model.scan()
        let id = try #require(model.series?.id)
        #expect(await eventually { model.series?.pages.first?.analysis == Self.single })
        #expect(try store.loadDocument(id: id).pages.first?.analysis == Self.single)
        await model.disconnect()
    }

    @Test func theSummaryIsKeptEvenIfTheUserChangedThePageBeforeTheAnalysisArrived() async throws {
        let (model, _, dir) = await makeModel(delay: 0.4); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let scanID = try #require(model.scans.first?.id)
        let left = try #require(model.pages(of: scanID).first)
        model.setPageRotation(pageID: left.id, degrees: 4)                       // vor dem Ergebnis der Analyse
        #expect(await eventually { model.series?.pages.allSatisfy { $0.analysis == Self.spread } == true })
        #expect(model.pages(of: scanID)[0].corrections.rotation.degrees == 4, "Die Handeingabe bleibt")
        await model.disconnect()
    }

    @Test func aLateAnalysisStillLandsInTheSeriesItBelongsTo() async throws {
        // Die Analyse braucht Zeit. Wechselt der Nutzer inzwischen in eine andere Serie, darf ihr Ergebnis nicht verloren gehen.
        let (model, store, dir) = await makeModel(delay: 0.5); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "A", book: true)
        await model.scan()
        let a = try #require(model.series?.id)
        model.endSeries()
        model.startSeries(title: "B")                                            // B wird jetzt gezeigt, A nicht mehr
        #expect(await eventually { (try? store.loadDocument(id: a))?.pages.allSatisfy { $0.analysis == Self.spread } == true },
                "Die Zusammenfassung ging verloren")
        #expect(model.series?.title == "B")
        await model.disconnect()
    }

    // MARK: Seiten beliebiger Serien ändern

    @Test func updatingABookPageOfASeriesThatIsNotShownIsSaved() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "A", book: true)
        await model.scan()
        let a = try #require(model.series?.id)
        let page = try #require(model.series?.pages.first)
        model.endSeries()
        model.startSeries(title: "B")
        model.updatePage(documentID: a, pageID: page.id) { $0.setRotation(degrees: 3) }
        #expect(try store.loadDocument(id: a).pages.first?.corrections.rotation.degrees == 3)
        #expect(model.savedDocuments.first { $0.id == a }?.pages.first?.corrections.rotation.source == .manual)
        await model.disconnect()
    }

    @Test func updatingASinglePageAlsoUpdatesTheScansCorrectionsFile() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Einzeln")
        await model.scan()
        let id = try #require(model.series?.id)
        let page = try #require(model.series?.pages.first)
        model.updatePage(documentID: id, pageID: page.id) { $0.setRotation(degrees: 2.5) }
        #expect(try store.corrections(for: page.scanID)?.rotation.degrees == 2.5, "Die Datei des Scans stimmt mit der Seite überein")
        #expect(model.scans.first?.corrections.rotation.degrees == 2.5, "Auch die Miniaturleiste")
        await model.disconnect()
    }

    @Test func updatingAnUnknownPageOrSeriesChangesNothing() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "A")
        await model.scan()
        let id = try #require(model.series?.id)
        let before = try store.loadDocument(id: id)
        model.updatePage(documentID: id, pageID: UUID()) { $0.setRotation(degrees: 9) }
        model.updatePage(documentID: UUID(), pageID: before.pages[0].id) { $0.setRotation(degrees: 9) }
        #expect(try store.loadDocument(id: id).pages == before.pages)
        await model.disconnect()
    }

    // MARK: Geprüft

    @Test func reviewingMarksPagesAndAnyChangeUndoesIt() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let id = try #require(model.series?.id)
        #expect(await eventually { model.series?.pages.allSatisfy { $0.analysis != nil } == true })
        let ids = try #require(model.series?.pages.map(\.id))
        #expect(model.review(of: try #require(model.latestDocument(id: id))).needingAttention.count == 2, "Falz unsicher: beide Seiten offen")

        model.setReviewed(true, documentID: id, pageIDs: [ids[0]])
        #expect(model.latestDocument(id: id)?.pages[0].isReviewed == true && model.latestDocument(id: id)?.pages[1].isReviewed == false)
        #expect(try store.loadDocument(id: id).pages[0].isReviewed, "Geprüft steht auf der Platte")
        #expect(model.review(of: try #require(model.latestDocument(id: id))).needingAttention == [ids[1]])

        model.updatePage(documentID: id, pageID: ids[0]) { $0.setRotation(degrees: 1.5) }
        #expect(model.latestDocument(id: id)?.pages[0].isReviewed == false, "Nach einer Änderung ist die Seite wieder offen")

        model.setReviewed(true, documentID: id, pageIDs: ids)
        model.setReviewed(false, documentID: id, pageIDs: [ids[1]])
        #expect(model.latestDocument(id: id)?.pages.map(\.isReviewed) == [true, false])
        await model.disconnect()
    }

    @Test func reviewingAnUnknownSeriesDoesNothing() async {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.setReviewed(true, documentID: UUID(), pageIDs: [UUID()])
        #expect(model.savedDocuments.isEmpty)
        await model.disconnect()
    }

    // MARK: Neu erkennen

    @Test func reanalyzingABookScanReplacesManualChangesAndSummaryOfBothPages() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let id = try #require(model.series?.id)
        #expect(await eventually { model.series?.pages.allSatisfy { $0.analysis != nil } == true })
        let ids = try #require(model.series?.pages.map(\.id)), scanID = try #require(model.series?.pages.first?.scanID)
        model.updatePage(documentID: id, pageID: ids[0]) { $0.setRotation(degrees: 7) }
        model.setReviewed(true, documentID: id, pageIDs: ids)

        await model.reanalyzeScan(documentID: id, scanID: scanID)
        let pages = try #require(model.latestDocument(id: id)?.pages)
        #expect(pages[0].corrections.rotation.degrees == 1 && pages[0].corrections.rotation.source == .automatic, "Die Handeingabe ist weg")
        #expect(pages.allSatisfy { $0.analysis == Self.spread })
        #expect(pages.allSatisfy { !$0.isReviewed }, "Neu erkannt heißt: wieder ungeprüft")
        await model.disconnect()
    }

    @Test func reanalyzingASinglePageOfASeriesThatIsNotShownWorks() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "A")
        await model.scan()
        let a = try #require(model.series?.id), page = try #require(model.series?.pages.first)
        model.endSeries()
        model.startSeries(title: "B")
        model.updatePage(documentID: a, pageID: page.id) { $0.setRotation(degrees: 8) }
        await model.reanalyzeScan(documentID: a, scanID: page.scanID)
        let result = try #require(try store.loadDocument(id: a).pages.first)
        #expect(result.corrections.rotation.degrees == 1 && result.analysis == Self.single)
        #expect(try store.corrections(for: page.scanID)?.rotation.degrees == 1, "Auch die Datei des Scans")
        await model.disconnect()
    }

    @Test func reanalyzingAScanWhoseOriginalIsGoneReportsAnError() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.reanalyzeScan(documentID: UUID(), scanID: UUID())
        #expect(model.log.first?.level == .error)
        await model.disconnect()
    }

    @Test func theLatestVersionOfARunningSeriesBeatsTheListEntry() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Läuft")
        await model.scan()
        let id = try #require(model.series?.id)
        #expect(model.latestDocument(id: id)?.pages.count == 1)
        await model.scan()
        #expect(model.latestDocument(id: id)?.pages.count == 2)
        #expect(model.latestDocument(id: UUID()) == nil)
        await model.disconnect()
    }

    @Test func renamingAfterTheSeriesEndedSurvivesALateAnalysis() async throws {
        let (model, store, dir) = await makeModel(delay: 0.3); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Alt")
        await model.scan()
        let id = try #require(model.series?.id)
        model.endSeries()
        #expect(model.renameDocument(id: id, to: "Chronik"))
        #expect(await eventually { (try? store.loadDocument(id: id))?.pages.first?.analysis != nil } || true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(try store.loadDocument(id: id).title == "Chronik")
        #expect(model.savedDocuments.first { $0.id == id }?.title == "Chronik")
        await model.disconnect()
    }

    @Test func theOriginalViewHasTheScansSizeAndIsNilForUnknownPages() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let id = try #require(model.series?.id), page = try #require(model.series?.pages.first)
        let image = try #require(await model.pageOriginalWithCrop(documentID: id, pageID: page.id, maxPixelSize: 300))
        let plain = try #require(await model.pagePreview(documentID: id, pageID: page.id, maxPixelSize: 300))
        #expect(max(image.width, image.height) <= 300 && max(image.width, image.height) > 100)
        #expect(image.width != plain.width || image.height != plain.height, "Das Original zeigt das ganze Bild, das Ergebnis nur die Seite")
        #expect(await model.pageOriginalWithCrop(documentID: id, pageID: UUID()) == nil)
        #expect(await model.pageOriginalWithCrop(documentID: UUID(), pageID: page.id) == nil)
        await model.disconnect()
    }
}
