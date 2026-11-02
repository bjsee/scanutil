import ArchiveKit
import Foundation
import ScannerKit
import Testing
@testable import ScanutilUI

@MainActor
@Suite("AppModel")
struct AppModelTests {
    private func makeModel(scanner: MockScanner = MockScanner()) -> (AppModel, MockScanner, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-ui-\(UUID().uuidString)")
        let model = AppModel(scanner: scanner, store: ArchiveStore(root: dir), thumbnailSize: 64)
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
        await model.stopPreview()
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
        await model.stopPreview()
    }

    @Test func scanMeasuresDuration() async {
        let (model, _, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(model.lastScanDuration == nil)
        await model.scan()
        #expect(model.lastScanDuration != nil)
        await model.stopPreview()
    }

    @Test func scanRestartsPreview() async {
        let (model, _, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        #expect(await eventually { model.previewImage != nil })
        await model.stopPreview()
    }

    @Test func scanFailureKeepsReadyAndShowsMessage() async {
        let (model, _, dir) = makeModel(scanner: MockScanner(captureFailure: .timeout)); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        #expect(model.status == .ready)
        #expect(model.scans.isEmpty)
        #expect(model.message == ScannerError.timeout.localizedDescription)
        await model.stopPreview()
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
        let capture = try await MockScanner().capture(format: ScanFormat(width: 320, height: 240), settings: .archival)
        let first = try store.store(capture, now: Date(timeIntervalSince1970: 1000))
        let second = try store.store(capture, now: Date(timeIntervalSince1970: 2000))
        await model.connect()
        #expect(model.scans.map(\.id) == [second.id, first.id])
        await model.stopPreview()
    }

    @Test func captureFormatPrefers5696OverLarger() {
        let formats = [ScanFormat(width: 7424, height: 5568), ScanFormat(width: 5696, height: 4272), ScanFormat(width: 4608, height: 3456)]
        #expect(AppModel.captureFormat(from: formats) == ScanFormat(width: 5696, height: 4272))
    }

    @Test func captureFormatFallsBackToLargest() {
        let formats = [ScanFormat(width: 640, height: 480), ScanFormat(width: 1280, height: 720)]
        #expect(AppModel.captureFormat(from: formats) == ScanFormat(width: 1280, height: 720))
    }

    @Test func previewFormatPicksNearTwoMegapixelFourToThree() {
        let formats = [ScanFormat(width: 1920, height: 1080), ScanFormat(width: 1536, height: 1152),
                       ScanFormat(width: 5696, height: 4272), ScanFormat(width: 640, height: 480)]
        #expect(AppModel.previewFormat(from: formats) == ScanFormat(width: 1536, height: 1152))
    }

    @Test func noFormatsMeansNoSelection() {
        #expect(AppModel.captureFormat(from: []) == nil)
        #expect(AppModel.previewFormat(from: []) == nil)
    }
}
