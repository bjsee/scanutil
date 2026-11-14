import ArchiveKit
import CoreGraphics
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

/// Bearbeiten in der Aufnahmeansicht: einen einzelnen Scan drehen, Original für den Zuschnittsrahmen laden.
@MainActor
@Suite("Aufnahme: Drehen und Zuschnitt")
struct CaptureEditTests {
    private func makeModel() async -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-capedit-\(UUID().uuidString)")
        let model = AppModel(scanner: MockScanner(formats: [ScanFormat(width: 640, height: 480)], previewsEnabled: false), store: ArchiveStore(root: dir),
                             thumbnailSize: 128, sound: SilentSound(), defaults: nil)
        await model.connect()
        return (model, dir)
    }

    private func waitForAnalysis(_ model: AppModel, _ id: UUID) async {
        for _ in 0..<160 {
            if model.scans.first(where: { $0.id == id })?.analysis != nil || !model.analyzing.contains(id) { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func turningAScanSetsTheOrientationSavesItAndKeepsWhatWasSetByHand() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.scan()
        let id = try #require(model.scans.first?.id)
        await waitForAnalysis(model, id)
        model.setRotation(id: id, degrees: 2)              // von Hand

        await model.turnScan(id: id, quarters: -1)
        let item = try #require(model.scans.first { $0.id == id })
        #expect(item.corrections.quarterTurns == 3, "Links drehen sind drei Vierteldrehungen im Uhrzeigersinn")
        #expect(item.corrections.rotation.degrees == 2 && item.corrections.rotation.source == .manual, "Die Drehung von Hand bleibt")
        #expect(try ArchiveStore(root: dir).corrections(for: id)?.quarterTurns == 3, "Gespeichert")

        await model.turnScan(id: id, quarters: 1)
        #expect(model.scans.first { $0.id == id }?.corrections.quarterTurns == 0)
        await model.turnScan(id: id, quarters: 4)
        #expect(model.scans.first { $0.id == id }?.corrections.quarterTurns == 0, "Eine volle Umdrehung ändert nichts")
        await model.turnScan(id: UUID(), quarters: 1)       // unbekannter Scan: nichts passiert
        await model.disconnect()
    }

    @Test func turningAScanRemeasuresTheSkewOnTheUprightPage() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.scan()
        let id = try #require(model.scans.first?.id)
        await waitForAnalysis(model, id)
        await model.turnScan(id: id, quarters: 1)
        let item = try #require(model.scans.first { $0.id == id })
        #expect(item.corrections.rotation.source == .automatic, "Von der Automatik gemessen, nicht von Hand")
        #expect(item.corrections.dewarp.wasMeasured, "Auch die Wölbung ist neu gemessen (mit oder ohne Ergebnis)")
        await model.disconnect()
    }

    @Test func theOriginalForTheCropFrameComesInReducedSizeAndIsNilForAnUnknownScan() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.scan()
        let id = try #require(model.scans.first?.id)
        let small = try #require(await model.scanOriginal(scanID: id, maxPixelSize: 200))
        #expect(max(small.width, small.height) <= 200 && max(small.width, small.height) > 100, "\(small.width)×\(small.height)")
        #expect(await model.scanOriginal(scanID: UUID()) == nil)
        await model.disconnect()
    }

    @Test func turningAScanInASeriesIsMirroredIntoTheSeriesPage() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Blätter")
        await model.scan()
        let id = try #require(model.scans.first?.id)
        await waitForAnalysis(model, id)
        await model.turnScan(id: id, quarters: 1)
        let page = try #require(model.series?.pages.first)
        #expect(page.corrections.quarterTurns == 1, "Die Seite der Serie trägt die Ausrichtung des Scans")
        await model.disconnect()
    }
}
