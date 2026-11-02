import ArchiveKit
import CoreGraphics
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

/// Die ganze Kette mit echter Analyse: Mock-Scanner liefert eine Textseite, `AppModel` scannt, archiviert, analysiert,
/// speichert Korrekturen und rendert die korrigierte Ansicht. Kein Stub, keine Hardware.
@MainActor
@Suite("Integration: Scan bis korrigierte Ansicht")
struct IntegrationTests {
    private func makeModel(delivering image: CGImage) -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-int-\(UUID().uuidString)")
        let model = AppModel(scanner: SyntheticPage.scanner(delivering: image), store: ArchiveStore(root: dir))
        return (model, dir)
    }

    private func eventually(seconds: Double = 15, _ condition: @MainActor () -> Bool) async -> Bool {
        let steps = Int(seconds / 0.05)
        for _ in 0..<steps {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func tiltedPageIsDetectedLevelledAndPersisted() async throws {
        let page = SyntheticPage.textPage(width: 1600, height: 1600, tiltCounterClockwise: 6, background: 10, raggedEdges: 30)
        let (model, dir) = makeModel(delivering: page); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        let id = try #require(model.scans.first?.id)

        // Die Analyse läuft im Hintergrund: warten, bis die korrigierte Ansicht da ist.
        #expect(await eventually { model.analyzing.isEmpty && model.scans.first?.corrected != nil })
        let item = try #require(model.scans.first)

        #expect(item.corrections.crop.quad != nil, "Dokument nicht erkannt: \(item.warnings)")
        #expect(item.corrections.crop.enabled)
        #expect(item.corrections.rotation.enabled, "Drehung nicht angewendet, Sicherheit \(String(describing: item.corrections.rotation.confidence))")
        #expect(!item.corrections.needsReview)

        // Nach der Korrektur steht der Text waagerecht (unabhängig gemessen am angezeigten Bild).
        let shown = try #require(item.corrected)
        let after = try #require(SkewEstimator.estimate(shown))
        #expect(abs(after.degrees) < 0.7, "Restwinkel nach Korrektur \(after.degrees)")

        // Gespeichert, das Original bleibt unberührt.
        let store = ArchiveStore(root: dir)
        #expect(try store.corrections(for: id) == item.corrections)
        #expect(try store.verify(item.record))
        await model.disconnect()
    }

    /// Text füllt das ganze Bild, es gibt keinen Rand: der Zuschnitt lässt die Neigung stehen, nur die Drehung kann sie beheben.
    /// Dieser Test hängt am Vorzeichen: eine falsch herum angewendete Drehung verdoppelt die Neigung.
    @Test(arguments: [6.0, -5.0, 11.0])
    func fullFrameTiltIsRemovedByRotationAlone(tilt: Double) async throws {
        let page = SyntheticPage.textPage(width: 1600, height: 1600, tiltCounterClockwise: tilt)
        let (model, dir) = makeModel(delivering: page); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        #expect(await eventually { model.analyzing.isEmpty && model.scans.first?.corrected != nil })
        let item = try #require(model.scans.first)

        // Die Automatik misst die Neigung mit dem richtigen Vorzeichen und wendet sie an.
        #expect(item.corrections.rotation.enabled)
        #expect(abs(item.corrections.rotation.degrees - tilt) < 0.4, "gemessen \(item.corrections.rotation.degrees), erwartet \(tilt)")

        let shown = try #require(item.corrected)
        let after = try #require(SkewEstimator.estimate(shown))
        #expect(abs(after.degrees) < 0.3, "Restwinkel \(after.degrees)")
        await model.disconnect()
    }

    @Test func handCorrectionOverridesAndSurvivesRestart() async throws {
        let page = SyntheticPage.textPage(width: 1600, height: 1600, tiltCounterClockwise: 4, background: 10)
        let (model, dir) = makeModel(delivering: page); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        let id = try #require(model.scans.first?.id)
        #expect(await eventually { model.analyzing.isEmpty })

        model.setRotation(id: id, degrees: 0.5)
        await model.disconnect()

        // Neustart: ein neues Modell auf demselben Archiv sieht die manuelle Korrektur.
        let again = AppModel(scanner: SyntheticPage.scanner(delivering: page), store: ArchiveStore(root: dir))
        await again.connect()
        let restored = try #require(again.scans.first)
        #expect(restored.id == id)
        #expect(restored.corrections.rotation.degrees == 0.5)
        #expect(restored.corrections.rotation.source == .manual)
        #expect(await eventually { again.scans.first?.corrected != nil })
        await again.disconnect()
    }

    @Test func blankPageIsNotCorrectedAndFlaggedForReview() async throws {
        let (model, dir) = makeModel(delivering: SyntheticPage.blank(width: 1200, height: 1200)); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        #expect(await eventually { model.analyzing.isEmpty && model.scans.first?.warnings.isEmpty == false })
        let item = try #require(model.scans.first)
        #expect(!item.corrections.rotation.enabled)
        #expect(item.warnings.contains { $0.contains("Schräglage") })
        await model.disconnect()
    }

    @Test func noiseIsNotRotated() async throws {
        let (model, dir) = makeModel(delivering: SyntheticPage.noise(width: 1200, height: 1200)); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        #expect(await eventually { model.analyzing.isEmpty && model.scans.first?.warnings.isEmpty == false })
        #expect(model.scans.first?.corrections.rotation.enabled == false)
        await model.disconnect()
    }

    @Test func severalScansKeepOneSessionAndAnalyzeEach() async throws {
        let page = SyntheticPage.textPage(width: 1600, height: 1600, tiltCounterClockwise: -5, background: 10)
        let scanner = SyntheticPage.scanner(delivering: page)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-int-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(scanner: scanner, store: ArchiveStore(root: dir))
        await model.connect()
        await model.scan()
        await model.scan()
        await model.scan()
        #expect(model.scans.count == 3)
        #expect(scanner.openedSessions == 1)
        #expect(await eventually(seconds: 30) { model.analyzing.isEmpty && model.scans.allSatisfy { $0.corrected != nil } })
        #expect(model.scans.allSatisfy { $0.corrections.rotation.enabled })
        await model.disconnect()
    }
}
