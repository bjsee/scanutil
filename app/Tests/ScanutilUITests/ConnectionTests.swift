import ArchiveKit
import CoreGraphics
import Foundation
import ScannerKit
import Testing
@testable import ScanutilUI

/// Der Scanner wird oft erst nach dem Start der App eingeschaltet. Die App muss ihn dann von selbst finden.
@MainActor
@Suite("Verbindung")
struct ConnectionTests {
    private func makeModel(_ scanner: MockScanner, retry: Duration? = .milliseconds(30)) -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-conn-\(UUID().uuidString)")
        return (AppModel(scanner: scanner, store: ArchiveStore(root: dir), thumbnailSize: 64, retryInterval: retry), dir)
    }

    private func eventually(timeout: Int = 120, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<timeout {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func aScannerSwitchedOnLaterIsFoundByItself() async {
        let scanner = MockScanner(startsSwitchedOff: true)
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(model.status == .failed(ScannerError.deviceNotFound.localizedDescription))
        #expect(model.isSearching)
        scanner.setSwitchedOn(true)
        #expect(await eventually { model.status == .ready })
        #expect(!model.isSearching)
        #expect(model.device?.name == "Mock-Scanner")
        #expect(await eventually { model.previewImage != nil })
        await model.disconnect()
    }

    @Test func scanningWorksAfterTheLateConnection() async {
        let scanner = MockScanner(startsSwitchedOff: true)
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        scanner.setSwitchedOn(true)
        #expect(await eventually { model.status == .ready })
        await model.scan()
        #expect(model.scans.count == 1)
        await model.disconnect()
    }

    @Test func retriesOpenExactlyOneSession() async {
        let scanner = MockScanner(startsSwitchedOff: true)
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(await eventually { scanner.connectAttempts >= 3 })
        scanner.setSwitchedOn(true)
        #expect(await eventually { model.status == .ready })
        #expect(scanner.openedSessions == 1, "Die Wiederholungen dürfen keine zweite Sitzung öffnen")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(scanner.openedSessions == 1)
        await model.disconnect()
        #expect(scanner.closedSessions == 1)
    }

    @Test func theSameErrorIsLoggedOnceNotOnEveryRetry() async {
        let scanner = MockScanner(startsSwitchedOff: true)
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(await eventually(timeout: 400) { scanner.connectAttempts > 5 }, "Es wurde nur \(scanner.connectAttempts)-mal versucht")
        #expect(model.log.filter { $0.level == .error }.count == 1)
        scanner.setSwitchedOn(true)
        #expect(await eventually { model.status == .ready })
        // Fehler und Erfolg stehen danach beide im Protokoll, der Erfolg zuletzt (also oben).
        #expect(model.log.first?.level == .info)
        #expect(model.log.first?.text.contains("Verbunden") == true)
        #expect(model.log.filter { $0.level == .error }.count == 1)
        await model.disconnect()
    }

    @Test func manualSearchConnectsWithoutWaitingForTheNextRetry() async {
        let scanner = MockScanner(startsSwitchedOff: true)
        let (model, dir) = makeModel(scanner, retry: .seconds(30)); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(model.isSearching)
        scanner.setSwitchedOn(true)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.status != .ready)          // der nächste automatische Versuch wäre erst in 30 Sekunden
        await model.connect()                    // „Jetzt suchen“
        #expect(model.status == .ready)
        #expect(!model.isSearching)
        await model.disconnect()
    }

    @Test func disconnectStopsTheSearch() async {
        let scanner = MockScanner(startsSwitchedOff: true)
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(model.isSearching)
        await model.disconnect()
        #expect(!model.isSearching)
        #expect(model.status == .disconnected)
        // Ein Versuch, der beim disconnect schon unterwegs war, wird vom Mock unter Umständen erst danach gezählt.
        // Gefragt ist, ob die Suche zum Stillstand kommt: nach einer Weile ändert sich die Zahl nicht mehr.
        try? await Task.sleep(for: .milliseconds(150))
        let settled = scanner.connectAttempts
        try? await Task.sleep(for: .milliseconds(400))
        #expect(scanner.connectAttempts == settled, "Nach disconnect wird weiter gesucht")
    }

    @Test func disconnectDuringAnAttemptDoesNotRestartTheSearch() async {
        // Der Versuch läuft noch, wenn disconnect kommt, und scheitert erst danach. Er darf die Suche nicht neu starten.
        let scanner = MockScanner(startsSwitchedOff: true, connectDelay: .milliseconds(200))
        let (model, dir) = makeModel(scanner, retry: .milliseconds(10)); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()                                          // erster Versuch, 200 ms
        #expect(await eventually(timeout: 200) { scanner.connectAttempts >= 2 })   // ein Versuch der Suche läuft jetzt
        await model.disconnect()
        let attempts = scanner.connectAttempts
        try? await Task.sleep(for: .milliseconds(600))
        #expect(scanner.connectAttempts == attempts, "Nach disconnect wurde neu gesucht (\(scanner.connectAttempts - attempts) Versuche)")
        #expect(!model.isSearching)
        #expect(model.status == .disconnected)
    }

    @Test func searchCanBeSwitchedOff() async {
        let scanner = MockScanner(startsSwitchedOff: true)
        let (model, dir) = makeModel(scanner, retry: nil); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!model.isSearching)
        #expect(scanner.connectAttempts == 1)
        #expect(model.status == .failed(ScannerError.deviceNotFound.localizedDescription))
    }

    @Test func nothingIsSearchedWhenAlreadyConnected() async {
        let scanner = MockScanner()
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(model.status == .ready)
        #expect(!model.isSearching)
        let attempts = scanner.connectAttempts
        try? await Task.sleep(for: .milliseconds(200))
        #expect(scanner.connectAttempts == attempts)
        await model.disconnect()
    }

    @Test func aFailingConnectionKeepsStatusStableWhileSearching() async {
        // Kein Flackern zwischen „Verbinde …“ und „Nicht verfügbar“ im Takt der Versuche.
        let (model, dir) = makeModel(MockScanner(startsSwitchedOff: true)); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        var seen = Set<String>()
        for _ in 0..<12 {
            seen.insert(String(describing: model.status))
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(seen.count == 1, "Status wechselte: \(seen)")
        await model.disconnect()
    }
}
