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
}
