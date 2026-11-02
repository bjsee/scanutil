import ArchiveKit
import CoreGraphics
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

@MainActor
@Suite("AppModel")
struct AppModelTests {
    /// Feste Analyse für die Tests: sichere automatische Korrekturen.
    nonisolated private static let confident = AnalysisResult(
        corrections: Corrections(
            crop: CropCorrection(quad: .full, enabled: true, source: .automatic, confidence: 0.9),
            rotation: RotationCorrection(degrees: 1.5, enabled: true, source: .automatic, confidence: 0.9)
        ),
        warnings: []
    )

    nonisolated private static let unsure = AnalysisResult(
        corrections: Corrections(
            crop: CropCorrection(quad: .full, enabled: true, source: .automatic, confidence: 0.9),
            rotation: RotationCorrection(degrees: 2.5, enabled: false, source: .automatic, confidence: 0.2)
        ),
        warnings: ["Die Schräglage ist unsicher."]
    )

    private func makeModel(
        scanner: MockScanner = MockScanner(),
        analyze: @escaping @Sendable (CGImage) -> AnalysisResult = { _ in AppModelTests.confident }
    ) -> (AppModel, MockScanner, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-ui-\(UUID().uuidString)")
        let model = AppModel(scanner: scanner, store: ArchiveStore(root: dir), thumbnailSize: 64, analyze: analyze)
        return (model, scanner, dir)
    }

    /// Wartet, bis die Bedingung gilt, höchstens zwei Sekunden.
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func connectBecomesReadyAndStartsPreview() async {
        let (model, _, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(model.status == .ready)
        #expect(model.device?.name == "Mock-Scanner")
        #expect(model.captureFormat != nil)
        #expect(await eventually { model.previewImage != nil })
        await model.disconnect()
    }

    @Test func connectFailureShowsMessage() async {
        let (model, _, dir) = makeModel(scanner: MockScanner(failure: .deviceNotFound)); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(model.status == .failed(ScannerError.deviceNotFound.localizedDescription))
    }

    @Test func scanStoresOriginalWithSharpnessZero() async throws {
        let (model, scanner, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()

        #expect(model.status == .ready)
        #expect(model.scans.count == 1)
        #expect(model.lastScan?.record.capture.sharpness == 0)
        #expect(scanner.calls.count == 1)
        #expect(scanner.calls[0].settings == .archival)
        let record = try #require(model.lastScan?.record)
        #expect(try ArchiveStore(root: dir).verify(record))
        await model.disconnect()
    }

    @Test func scanMeasuresDuration() async {
        let (model, _, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(model.lastScanDuration == nil)
        await model.scan()
        #expect(model.lastScanDuration != nil)
        await model.disconnect()
    }

    @Test func previewKeepsRunningDuringScan() async {
        let (model, scanner, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        await model.scan()
        // Eine Sitzung für alle Scans, kein Neuaufbau dazwischen.
        #expect(scanner.openedSessions == 1)
        #expect(scanner.closedSessions == 0)
        #expect(await eventually { model.previewImage != nil })
        await model.disconnect()
        #expect(scanner.closedSessions == 1)
    }

    @Test func disconnectClosesSessionAndStopsScanning() async {
        let (model, scanner, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.disconnect()
        #expect(model.status == .disconnected)
        #expect(model.previewImage == nil)
        await model.scan()
        #expect(scanner.calls.isEmpty)
    }

    @Test func scanFailureKeepsReadyAndShowsMessage() async {
        let (model, _, dir) = makeModel(scanner: MockScanner(captureFailure: .timeout)); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        #expect(model.status == .ready)
        #expect(model.scans.isEmpty)
        #expect(model.message == ScannerError.timeout.localizedDescription)
        await model.disconnect()
    }

    @Test func scanIgnoredWhenNotReady() async {
        let (model, scanner, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.scan()
        #expect(scanner.calls.isEmpty)
        #expect(model.scans.isEmpty)
    }

    @Test func connectLoadsExistingScansNewestFirst() async throws {
        let (model, _, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveStore(root: dir)
        let session = try await MockScanner().openSession(format: ScanFormat(width: 320, height: 240), settings: .archival)
        let capture = try await session.capture()
        await session.close()
        let first = try store.store(capture, now: Date(timeIntervalSince1970: 1000))
        let second = try store.store(capture, now: Date(timeIntervalSince1970: 2000))
        await model.connect()
        #expect(model.scans.map(\.id) == [second.id, first.id])
        await model.disconnect()
    }

    @Test func captureFormatPrefers5696OverLarger() {
        let formats = [ScanFormat(width: 7424, height: 5568), ScanFormat(width: 5696, height: 4272), ScanFormat(width: 4608, height: 3456)]
        #expect(AppModel.captureFormat(from: formats) == ScanFormat(width: 5696, height: 4272))
    }

    @Test func captureFormatFallsBackToLargest() {
        let formats = [ScanFormat(width: 640, height: 480), ScanFormat(width: 1280, height: 720)]
        #expect(AppModel.captureFormat(from: formats) == ScanFormat(width: 1280, height: 720))
    }

    @Test func noFormatsMeansNoSelection() {
        #expect(AppModel.captureFormat(from: []) == nil)
    }

    // MARK: Korrekturen

    @Test func scanIsAnalyzedAndCorrectionsArePersisted() async throws {
        let (model, _, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        #expect(await eventually { model.scans.first?.corrections.rotation.degrees == 1.5 })
        let id = try #require(model.scans.first?.id)
        #expect(try ArchiveStore(root: dir).corrections(for: id) == AppModelTests.confident.corrections)
        #expect(model.selectedID == id)
        #expect(await eventually { model.analyzing.isEmpty })
        await model.disconnect()
    }

    @Test func unsureAnalysisIsSuggestedNotApplied() async {
        let (model, _, dir) = makeModel(analyze: { _ in AppModelTests.unsure }); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        #expect(await eventually { model.scans.first?.warnings.isEmpty == false })
        let item = model.scans[0]
        #expect(item.corrections.needsReview)
        #expect(!item.corrections.rotation.enabled)
        #expect(item.corrections.rotation.degrees == 2.5)
        await model.disconnect()
    }

    @Test func manualRotationIsPersistedAndMarkedManual() async throws {
        let (model, _, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        #expect(await eventually { model.scans.first?.corrections.revision == 0 && model.scans.first?.corrections.rotation.degrees == 1.5 })
        let id = try #require(model.scans.first?.id)
        model.setRotation(id: id, degrees: -3.25)
        let saved = try #require(try ArchiveStore(root: dir).corrections(for: id))
        #expect(saved.rotation.degrees == -3.25)
        #expect(saved.rotation.source == .manual)
        #expect(saved.rotation.enabled)
        #expect(saved.revision >= 1)
        #expect(await eventually { model.scans.first?.corrected != nil })
        await model.disconnect()
    }

    @Test func manualEditDuringAnalysisIsNotOverwritten() async throws {
        let slow: @Sendable (CGImage) -> AnalysisResult = { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return AppModelTests.confident
        }
        let (model, _, dir) = makeModel(analyze: slow); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        let id = try #require(model.scans.first?.id)
        model.setRotation(id: id, degrees: 4)
        #expect(await eventually { model.analyzing.isEmpty })
        #expect(model.scans.first?.corrections.rotation.degrees == 4)
        #expect(model.scans.first?.corrections.rotation.source == .manual)
        await model.disconnect()
    }

    @Test func reanalyzeDiscardsManualChanges() async throws {
        let (model, _, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        let id = try #require(model.scans.first?.id)
        model.setRotation(id: id, degrees: 7)
        await model.reanalyze(id: id)
        #expect(model.scans.first?.corrections.rotation.degrees == 1.5)
        #expect(model.scans.first?.corrections.rotation.source == .automatic)
        await model.disconnect()
    }

    @Test func masterSwitchOffIsPersistedAndOriginalStaysUntouched() async throws {
        let (model, _, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        let item = try #require(model.scans.first)
        model.setCorrectionsEnabled(id: item.id, false)
        #expect(try ArchiveStore(root: dir).corrections(for: item.id)?.enabled == false)
        #expect(try ArchiveStore(root: dir).verify(item.record))
        await model.disconnect()
    }

    @Test func existingScansLoadWithTheirCorrections() async throws {
        let (model, _, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveStore(root: dir)
        let session = try await MockScanner().openSession(format: ScanFormat(width: 320, height: 240), settings: .archival)
        let record = try store.store(try await session.capture())
        await session.close()
        var corrections = Corrections()
        corrections.setRotation(degrees: -2)
        try store.saveCorrections(corrections, for: record.id)

        await model.connect()
        #expect(model.scans.first?.corrections == corrections)
        #expect(model.selectedID == record.id)
        await model.disconnect()
    }
}
