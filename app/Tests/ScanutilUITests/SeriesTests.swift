import ArchiveKit
import CoreGraphics
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

@MainActor
@Suite("Serienmodus")
struct SeriesTests {
    nonisolated private static let confident = AnalysisResult(
        corrections: Corrections(rotation: RotationCorrection(degrees: 1.5, enabled: true, source: .automatic, confidence: 0.9)),
        warnings: []
    )

    /// Ohne eigene Vorschaubilder des Mocks: der Trigger bekommt nur die Signaturen, die der Test einspeist.
    private func makeModel() async -> (AppModel, ArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-series-\(UUID().uuidString)")
        let store = ArchiveStore(root: dir)
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: store, thumbnailSize: 64,
                             analyze: { _ in SeriesTests.confident })
        await model.connect()
        return (model, store, dir)
    }

    private func page(row: Int?) -> FrameSignature {
        var cells = [UInt8](repeating: 230, count: FrameSignature.width * FrameSignature.height)
        if let row { for x in 4..<40 { cells[row * FrameSignature.width + x] = 40 } }
        return FrameSignature(cells: cells)!
    }

    private let hand: FrameSignature = {
        var cells = [UInt8](repeating: 230, count: FrameSignature.width * FrameSignature.height)
        for i in 0..<(cells.count / 3) { cells[i] = 60 }
        return FrameSignature(cells: cells)!
    }()

    /// Zehn Bilder pro Sekunde, `seconds` lang.
    private func feed(_ model: AppModel, _ frame: FrameSignature, from start: Double, seconds: Double) async {
        var t = start
        while t < start + seconds - 1e-9 { await model.processSeriesFrame(frame, at: t); t += 0.1 }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func startSavesAnEmptyDocument() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Chronik")
        let id = try #require(model.series?.id)
        #expect(model.isSeriesActive)
        #expect(try store.loadDocument(id: id).pages.isEmpty)
        model.endSeries()
        #expect(!model.isSeriesActive)
        #expect(try store.loadDocument(id: id).title == "Chronik")   // bleibt gespeichert
        await model.disconnect()
    }

    @Test func cannotStartWithoutConnection() {
        let model = AppModel(scanner: MockScanner(previewsEnabled: false),
                             store: ArchiveStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID())")))
        model.startSeries(title: "T")
        #expect(!model.isSeriesActive)
    }

    @Test func calmAfterMotionCapturesAndAppendsPage() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Auto")
        await feed(model, page(row: 5), from: 0, seconds: 2)
        #expect(model.scans.count == 1)
        let doc = try store.loadDocument(id: try #require(model.series?.id))
        #expect(doc.pages.map(\.scanID) == [model.scans[0].id])
        await model.disconnect()
    }

    @Test func pageTurnsBuildTheDocumentInOrder() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch")
        await feed(model, page(row: 5), from: 0, seconds: 2)
        await feed(model, hand, from: 2, seconds: 0.6)
        await feed(model, page(row: 20), from: 2.6, seconds: 2)
        await feed(model, hand, from: 4.6, seconds: 0.6)
        await feed(model, page(row: 12), from: 5.2, seconds: 2)
        #expect(model.scans.count == 3)
        let doc = try store.loadDocument(id: try #require(model.series?.id))
        // scans ist neueste zuerst, das Dokument älteste zuerst.
        #expect(doc.pages.map(\.scanID) == model.scans.reversed().map(\.id))
        await model.disconnect()
    }

    @Test func unchangedPageIsNotCapturedTwice() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Dublette")
        await feed(model, page(row: 5), from: 0, seconds: 2)
        await feed(model, hand, from: 2, seconds: 0.6)
        await feed(model, page(row: 5), from: 2.6, seconds: 2)
        #expect(model.scans.count == 1)
        #expect(model.message?.contains("unverändert") == true)
        await model.disconnect()
    }

    @Test func manualOnlyModeStillFillsDocument() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Hand")
        model.autoTriggerEnabled = false
        await feed(model, page(row: 5), from: 0, seconds: 3)
        #expect(model.scans.isEmpty)
        await model.scan()
        #expect(model.scans.count == 1)
        #expect(try store.loadDocument(id: try #require(model.series?.id)).pages.count == 1)
        await model.disconnect()
    }

    @Test func manualScanBlocksAutoShotOfSamePage() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Hand und Auto")
        await model.processSeriesFrame(page(row: 5), at: 0)
        await model.scan()
        await feed(model, page(row: 5), from: 0.1, seconds: 3)
        #expect(model.scans.count == 1)
        await model.disconnect()
    }

    @Test func noPagesWithoutSeries() async {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await feed(model, page(row: 5), from: 0, seconds: 3)
        #expect(model.scans.isEmpty)
        await model.scan()
        #expect(model.scans.count == 1)
        #expect(model.series == nil)
        await model.disconnect()
    }

    @Test func correctionsAreMirroredIntoThePage() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Korrekturen")
        await model.scan()
        let scanID = try #require(model.scans.first?.id)
        // Die Analyse läuft im Hintergrund; danach trägt die Seite dieselbe Drehung wie der Scan.
        #expect(await eventually { model.series?.pages.first?.corrections.rotation.degrees == 1.5 })
        model.setRotation(id: scanID, degrees: -0.5)
        let doc = try store.loadDocument(id: try #require(model.series?.id))
        #expect(doc.pages.first?.corrections.rotation.degrees == -0.5)
        #expect(doc.pages.first?.corrections.rotation.source == .manual)
        await model.disconnect()
    }
}
