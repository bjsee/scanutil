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

    // MARK: Verlust im laufenden Betrieb

    private static let lostText = AppModel.connectionLostText

    @Test func unplugDuringOperationIsDetectedAndTheAppReconnectsWhenItIsBack() async {
        let scanner = MockScanner()
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(model.status == .ready)
        #expect(await eventually { model.previewImage != nil })

        scanner.simulateConnectionLoss()
        #expect(await eventually { model.status == .failed(Self.lostText) }, "Status: \(model.status)")
        #expect(model.isSearching)
        #expect(model.previewImage == nil, "Ein eingefrorenes Bild bleibt stehen")
        #expect(scanner.closedSessions == 1, "Die verlorene Sitzung muss geschlossen werden")
        #expect(model.log.contains { $0.level == .error && $0.text == Self.lostText })

        scanner.setSwitchedOn(true)
        #expect(await eventually { model.status == .ready }, "Status: \(model.status)")
        #expect(!model.isSearching)
        #expect(scanner.openedSessions == 2)
        #expect(await eventually { model.previewImage != nil }, "Die Vorschau kommt nach dem Wiederverbinden nicht zurück")
        await model.scan()
        #expect(model.scans.count == 1)
        await model.disconnect()
    }

    @Test func aSeriesAndItsScansSurviveAnUnplug() async throws {
        let scanner = MockScanner(previewsEnabled: false)
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        model.startSeries(title: "Chronik")
        await model.scan()
        let documentID = try #require(model.series?.id)
        let firstScan = try #require(model.scans.first?.id)

        scanner.simulateConnectionLoss()
        #expect(await eventually { model.status == .failed(Self.lostText) })
        #expect(model.isSeriesActive, "Die Serie wurde beendet")
        #expect(model.scans.map(\.id) == [firstScan], "Die Scans gingen verloren")

        scanner.setSwitchedOn(true)
        #expect(await eventually { model.status == .ready })
        #expect(model.scans.map(\.id).contains(firstScan), "Das Wiederverbinden hat die Scans neu geladen")
        await model.scan()
        #expect(model.series?.id == documentID)
        #expect(model.series?.pages.count == 2, "Die zweite Seite gehört in dasselbe Dokument")
        await model.disconnect()
    }

    @Test func unplugInTheMiddleOfACaptureEndsInLostNotReady() async {
        let scanner = MockScanner(previewsEnabled: false, captureDelay: .seconds(10))   // endet mit dem Verlust, nicht nach der Zeit
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        let capture = Task { await model.scan() }
        #expect(await eventually { model.status == .capturing })
        scanner.simulateConnectionLoss()
        await capture.value

        #expect(model.status == .failed(Self.lostText), "Status nach verlorener Aufnahme: \(model.status)")
        #expect(model.scans.isEmpty)
        #expect(model.isSearching)
        // Nur die Meldung über den Verlust, nicht zusätzlich ein Fehler „Gerät nicht gefunden“ der Aufnahme.
        #expect(model.log.filter { $0.level == .error }.map(\.text) == [Self.lostText])
        await model.disconnect()
    }

    @Test func aScanTriggeredWhileLostIsImpossible() async {
        let scanner = MockScanner(previewsEnabled: false)
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        scanner.simulateConnectionLoss()
        #expect(await eventually { model.status == .failed(Self.lostText) })
        await model.scan()
        #expect(model.scans.isEmpty)
        #expect(model.status == .failed(Self.lostText))
        await model.disconnect()
    }

    @Test func theAppSurvivesSeveralUnplugsAndOpensOneSessionEach() async {
        let scanner = MockScanner(previewsEnabled: false)
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        for round in 1...3 {
            scanner.simulateConnectionLoss()
            #expect(await eventually { model.status == .failed(Self.lostText) }, "Runde \(round): \(model.status)")
            scanner.setSwitchedOn(true)
            #expect(await eventually { model.status == .ready }, "Runde \(round): \(model.status)")
        }
        #expect(scanner.openedSessions == 4)
        #expect(scanner.closedSessions == 3)
        #expect(model.log.filter { $0.text == Self.lostText }.count == 3, "Jeder Verlust genau einmal im Protokoll")
        await model.disconnect()
        #expect(scanner.closedSessions == 4)
    }

    @Test func unplugAfterDisconnectChangesNothing() async {
        let scanner = MockScanner(previewsEnabled: false)
        let (model, dir) = makeModel(scanner); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.disconnect()
        let before = model.log.count
        scanner.simulateConnectionLoss()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.status == .disconnected)
        #expect(!model.isSearching)
        #expect(model.log.count == before)
    }

    @Test func withoutRetryAnUnplugEndsInLostWithoutSearching() async {
        let scanner = MockScanner(previewsEnabled: false)
        let (model, dir) = makeModel(scanner, retry: nil); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        scanner.simulateConnectionLoss()
        #expect(await eventually { model.status == .failed(Self.lostText) })
        #expect(!model.isSearching)
        await model.disconnect()
    }

    @Test func aManualSearchAfterAnUnplugReconnects() async {
        let scanner = MockScanner(previewsEnabled: false)
        let (model, dir) = makeModel(scanner, retry: .seconds(30)); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        scanner.simulateConnectionLoss()
        #expect(await eventually { model.status == .failed(Self.lostText) })
        scanner.setSwitchedOn(true)
        await model.connect()                     // „Jetzt suchen“, ohne auf den Takt zu warten
        #expect(model.status == .ready)
        await model.disconnect()
    }
}
