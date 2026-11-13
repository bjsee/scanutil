import ArchiveKit
import Foundation
import ScannerKit
import Testing
@testable import ScanutilUI

@MainActor
@Suite("Scanner hängt nach der Gerätetaste")
struct ScannerStuckTests {
    private func eventually(timeout: Double = 60, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    private func makeModel(_ scanner: MockScanner) async -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-stuck-\(UUID().uuidString)")
        let model = AppModel(scanner: scanner, store: ArchiveStore(root: dir), thumbnailSize: 64,
                             retryInterval: .milliseconds(20), stuckThresholds: (shortSession: 1.0, window: 30),
                             sound: SilentSound(), defaults: nil)
        return (model, dir)
    }

    @Test func aDeviceThatKeepsFallingSilentIsRecognizedAsStuckAndNamedAsSuch() async throws {
        let scanner = MockScanner(previewsEnabled: false)
        scanner.setFlapping(after: 0.05)
        let (model, dir) = await makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(await eventually { model.scannerStuck }, "Zwei kurze Sitzungen hintereinander: der Scanner hängt. Status \(model.status), Sitzungen \(scanner.openedSessions), Versuche \(scanner.connectAttempts), Protokoll \(model.log.prefix(4).map(\.text))")
        #expect(model.status == .failed(AppModel.scannerStuckText))
        #expect(model.log.filter { $0.text == AppModel.scannerStuckText }.count == 1, "Die Meldung steht einmal im Protokoll")
        await model.disconnect()
    }

    @Test func aStuckScannerIsNotBotheredAtTheNormalPace() async throws {
        let scanner = MockScanner(previewsEnabled: false)
        scanner.setFlapping(after: 0.05)
        let (model, dir) = await makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(await eventually { model.scannerStuck })
        let before = scanner.openedSessions
        try await Task.sleep(for: .milliseconds(500))
        let attempts = scanner.openedSessions - before
        #expect(attempts <= 6, "Im Sekundentakt der Suche (20 ms) wären es ~25 Versuche gewesen, es waren \(attempts)")
        await model.disconnect()
    }

    @Test func afterReplugTheScannerWorksAgainAndTheWarningGoes() async throws {
        let scanner = MockScanner(previewsEnabled: false)
        scanner.setFlapping(after: 0.05)
        let (model, dir) = await makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(await eventually { model.scannerStuck })
        scanner.setFlapping(after: nil)          // Kabel neu gesteckt
        #expect(await eventually(timeout: 60) { model.status == .ready && !model.scannerStuck }, "Status: \(model.status), hängt: \(model.scannerStuck)")
        await model.scan()
        #expect(model.scans.count == 1, "Aufnehmen geht wieder")
        await model.disconnect()
    }

    @Test func twoUnplugsWithAMissingDeviceBetweenThemAreNotStuck() async throws {
        let scanner = MockScanner(previewsEnabled: false)
        let (model, dir) = await makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        for _ in 0..<3 {
            scanner.simulateConnectionLoss()
            #expect(await eventually { model.status == .failed(AppModel.connectionLostText) })
            try await Task.sleep(for: .milliseconds(100))        // das Gerät ist weg: Versuche scheitern
            scanner.setSwitchedOn(true)
            #expect(await eventually { model.status == .ready })
        }
        #expect(!model.scannerStuck)
        await model.disconnect()
    }

    @Test func aNormalUnplugAfterALongSessionIsNotStuck() async throws {
        let scanner = MockScanner(previewsEnabled: false)
        let (model, dir) = await makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        try await Task.sleep(for: .milliseconds(1800))    // länger als die kurze Sitzung
        scanner.simulateConnectionLoss()
        #expect(await eventually { model.status == .failed(AppModel.connectionLostText) })
        #expect(!model.scannerStuck)
        scanner.setSwitchedOn(true)
        #expect(await eventually { model.status == .ready })
        await model.disconnect()
    }

    @Test func twoUnplugsFarApartAreNotStuckEither() async throws {
        let scanner = MockScanner(previewsEnabled: false)
        let (model, dir) = await makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        scanner.simulateConnectionLoss()
        #expect(await eventually { model.status == .failed(AppModel.connectionLostText) })
        scanner.setSwitchedOn(true)
        #expect(await eventually { model.status == .ready })
        try await Task.sleep(for: .milliseconds(1800))    // die neue Sitzung hält lange
        scanner.simulateConnectionLoss()
        #expect(await eventually { model.status == .failed(AppModel.connectionLostText) })
        #expect(!model.scannerStuck, "Zwei Abzieh-Vorgänge mit einer langen Sitzung dazwischen sind keine Störung des Geräts")
        await model.disconnect()
    }
}
