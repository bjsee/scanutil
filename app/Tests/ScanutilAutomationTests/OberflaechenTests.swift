import ApplicationServices
import Foundation
import Testing

/// Bedient die echte App (Fenster, Schaltflächen, Regler, Leertaste) im Dokumentmodus und prüft das Ergebnis auf der Platte.
/// Läuft nur mit `SCANUTIL_UI_TESTS=1`, weil dabei Fenster aufgehen und die App kurz in den Vordergrund kommt.
@Suite("Oberfläche", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SCANUTIL_UI_TESTS"] != nil))
struct OberflaechenTests {
    private struct Session {
        let app: AppDriver
        let dir: URL
        func close() { app.terminate() }
    }

    private func launch(mode: String = "document", archive: URL? = nil) throws -> Session {
        let dir = archive ?? FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-ui-\(UUID().uuidString)")
        let app = try AppDriver(mode: mode, archive: dir)
        let ready = app.wait { app.string("status-text")?.hasPrefix("Bereit") == true }
        #expect(ready, "App wurde nicht bereit")
        return Session(app: app, dir: dir)
    }

    private func originals(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("originals"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
    }

    private func correctionFiles(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("corrections"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private func corrections(_ dir: URL) -> [String: Any]? {
        guard let file = correctionFiles(dir).first, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func rotation(_ dir: URL) -> [String: Any]? { corrections(dir)?["rotation"] as? [String: Any] }

    /// Scannt einmal über die Schaltfläche und wartet, bis Original, Analyse und Detailansicht da sind.
    private func scanOnce(_ s: Session, expecting count: Int = 1) {
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { originals(s.dir).count == count }, "Original wurde nicht archiviert")
        #expect(s.app.wait(timeout: 30) { correctionFiles(s.dir).count == count }, "Korrekturen wurden nicht gespeichert")
    }

    // MARK: Tests

    @Test func appStartsAndIsReady() throws {
        #expect(AXIsProcessTrusted(), "Bedienungshilfen sind für dieses Programm nicht erlaubt")
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        #expect(s.app.string("status-text") == "Bereit: Mock-Scanner")
        #expect(s.app.isEnabled("scan-button") == true)
    }

    @Test func clickingScanArchivesTheOriginal() throws {
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        scanOnce(s)
        #expect(s.app.wait { s.app.element("rotation-slider") != nil }, "Detailansicht erscheint nicht")
        #expect(s.app.wait { s.app.string("thumbnail-strip") == "1" }, "Miniaturen: \(s.app.string("thumbnail-strip") ?? "keine Leiste")")
    }

    @Test func spaceBarTriggersScan() throws {
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        #expect(s.app.pressSpace())
        #expect(s.app.wait { originals(s.dir).count == 1 }, "Leertaste hat keinen Scan ausgelöst")
    }

    @Test func automaticCorrectionsAreAppliedWithoutWarning() throws {
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        scanOnce(s)
        #expect(s.app.wait { s.app.element("rotation-slider") != nil })
        #expect(s.app.element("review-banner") == nil, "Prüfhinweis bei sicherer Erkennung")
        #expect(s.app.number("rotation-toggle") == 1)
        #expect(corrections(s.dir)?["enabled"] as? Bool == true)
        #expect((rotation(s.dir)?["source"] as? String) == "automatic")
    }

    @Test func sliderChangeIsStoredAsManualRotation() throws {
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        scanOnce(s)
        #expect(s.app.wait { s.app.element("rotation-slider") != nil })
        let reached = s.app.adjust("rotation-slider", to: 3.5)
        #expect(reached.map { abs($0 - 3.5) < 0.06 } ?? false, "Regler erreichte \(String(describing: reached))")
        #expect(s.app.wait { (self.rotation(s.dir)?["degrees"] as? Double).map { abs($0 - 3.5) < 0.06 } ?? false }, "Winkel wurde nicht gespeichert")
        #expect((rotation(s.dir)?["source"] as? String) == "manual")
        let shown = s.app.wait { s.app.numberInText("rotation-value").map { abs($0 - 3.5) < 0.06 } ?? false }
        #expect(shown, "Anzeige zeigt \(s.app.string("rotation-value") ?? "nichts")")
    }

    @Test func paperLighteningIsOnByDefaultAndCanBeSwitchedOff() throws {
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        scanOnce(s)
        func tone() -> [String: Any]? { corrections(s.dir)?["tone"] as? [String: Any] }
        #expect(s.app.wait { s.app.element("tone-toggle") != nil }, "Kein Schalter „Papier aufhellen“")
        #expect(s.app.wait { (tone()?["enabled"] as? Bool) == true }, "Die Automatik schaltet das Aufhellen ein: \(String(describing: tone()))")
        #expect(s.app.number("tone-toggle") == 1)
        #expect(s.app.press("tone-toggle"))
        #expect(s.app.wait { (tone()?["enabled"] as? Bool) == false && (tone()?["source"] as? String) == "manual" }, "Ausschalten wird nicht als Handeingabe gespeichert")
    }

    @Test func theCaptureViewOffersTheCropFrameWholeImageAndTurningLikeTheEditor() throws {
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        scanOnce(s)
        #expect(s.app.wait { s.app.element("scan-crop-edit") != nil }, "Kein Knopf „Rahmen ziehen“ in der Aufnahme")

        // Rahmen ziehen: Der Editor mit den vier Ecken erscheint und lässt sich wieder schließen.
        #expect(s.app.press("scan-crop-edit"))
        #expect(s.app.wait { s.app.element("scan-crop-editor") != nil }, "Der Zuschnittsrahmen öffnet sich nicht")
        #expect(s.app.wait { s.app.element("scan-crop-handle-topLeft") != nil && s.app.element("scan-crop-handle-bottomRight") != nil }, "Die Ecken fehlen")
        #expect(s.app.press("scan-crop-edit"))
        #expect(s.app.wait { s.app.element("scan-crop-editor") == nil }, "Der Rahmen schließt sich nicht")

        // Ganzes Bild: manueller, aktiver Zuschnitt auf das ganze Bild.
        #expect(s.app.press("scan-crop-full"))
        #expect(s.app.wait {
            let crop = self.corrections(s.dir)?["crop"] as? [String: Any]
            return (crop?["source"] as? String) == "manual" && (crop?["enabled"] as? Bool) == true
        }, "Ganzes Bild wurde nicht als manueller Zuschnitt gespeichert")

        // Links drehen, dann rechts drehen.
        func turns() -> Int? { corrections(s.dir)?["quarterTurns"] as? Int }
        #expect(s.app.press("scan-turn-left"))
        #expect(s.app.wait(timeout: 20) { turns() == 3 }, "Links drehen ist nicht gespeichert: \(String(describing: turns()))")
        #expect(s.app.wait { s.app.element("scan-turn-state") != nil }, "Die Ausrichtung wird nicht angezeigt")
        #expect(s.app.press("scan-turn-right"))
        #expect(s.app.wait(timeout: 20) { turns() == 0 }, "Rechts drehen macht es nicht rückgängig: \(String(describing: turns()))")
    }

    @Test func theSidebarShowsWhichVersionIsRunningAndItMatchesTheBuiltBundle() throws {
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        #expect(s.app.wait { s.app.element("app-version") != nil }, "Keine Versionsanzeige in der Seitenleiste")
        let shown = s.app.string("app-version") ?? ""
        #expect(shown.range(of: #"^Version \d{2}\.\d{2}\.\d{4} \d{2}:\d{2}$"#, options: .regularExpression) != nil, "Anzeige: „\(shown)“")

        // Dieselbe Zeit steht in der Info.plist des Bündels, das die Tests gestartet haben (gebaut von bundle.sh).
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/Chronik-Scanner.app/Contents/Info.plist")
        let info = NSDictionary(contentsOf: plist)
        let raw = info?["ScanutilBuildTimestamp"] as? String
        #expect(raw != nil, "Die Info.plist hat keinen Zeitstempel: \(plist.path)")
        if let raw {
            let parts = raw.split(separator: " ")                     // „2026-11-14 09:41:07“
            let date = parts[0].split(separator: "-"), time = parts[1].split(separator: ":")
            #expect(shown == "Version \(date[2]).\(date[1]).\(date[0]) \(time[0]):\(time[1])", "Anzeige „\(shown)“, Info.plist „\(raw)“")
        }
        #expect((info?["ScanutilBuildCommit"] as? String)?.isEmpty == false, "Der Commit fehlt in der Info.plist")
    }

    @Test func theCaptureViewHasTheHistoricDocumentCrop() throws {
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        scanOnce(s)
        #expect(s.app.wait { s.app.element("scan-crop-historic") != nil }, "Kein Knopf „Historisches Dokument“ in der Aufnahme")
        #expect(s.app.press("scan-crop-historic"))
        #expect(s.app.wait(timeout: 20) {
            let crop = self.corrections(s.dir)?["crop"] as? [String: Any]
            return (crop?["source"] as? String) == "manual" && (crop?["enabled"] as? Bool) == true && crop?["quad"] != nil
        }, "„Historisches Dokument“ wurde nicht als Zuschnitt gespeichert")
    }

    @Test func masterSwitchDisablesCorrectionsAndControls() throws {
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        scanOnce(s)
        #expect(s.app.wait { s.app.element("master-toggle") != nil })
        #expect(s.app.press("master-toggle"))
        #expect(s.app.wait { (self.corrections(s.dir)?["enabled"] as? Bool) == false }, "Hauptschalter wurde nicht gespeichert")
        #expect(s.app.wait { s.app.isEnabled("rotation-slider") == false }, "Regler bleibt aktiv")
        #expect(s.app.press("master-toggle"))
        #expect(s.app.wait { (self.corrections(s.dir)?["enabled"] as? Bool) == true })
        #expect(s.app.wait { s.app.isEnabled("rotation-slider") == true })
    }

    @Test func reanalyzeReplacesManualCorrection() throws {
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        scanOnce(s)
        #expect(s.app.wait { s.app.element("rotation-slider") != nil })
        #expect(s.app.adjust("rotation-slider", to: 9) != nil)
        #expect(s.app.wait { (self.rotation(s.dir)?["source"] as? String) == "manual" })
        #expect(s.app.press("reanalyze-button"))
        #expect(s.app.wait(timeout: 30) { (self.rotation(s.dir)?["source"] as? String) == "automatic" }, "Neu erkennen hat die manuelle Korrektur nicht ersetzt")
        #expect((rotation(s.dir)?["degrees"] as? Double).map { abs($0 - 9) > 1 } ?? false)
    }

    @Test func unsureAnalysisShowsReviewBannerAndAppliesNothing() throws {
        let s = try launch(mode: "noise"); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        scanOnce(s)
        #expect(s.app.wait(timeout: 20) { s.app.element("review-banner") != nil }, "Kein Prüfhinweis bei unsicherer Analyse")
        #expect(s.app.number("rotation-toggle") == 0, "Unsichere Drehung wurde angewendet")
        #expect((rotation(s.dir)?["enabled"] as? Bool) == false)
    }

    @Test func manualCorrectionSurvivesRestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let s = try launch(archive: dir); defer { s.close() }
            scanOnce(s)
            #expect(s.app.wait { s.app.element("rotation-slider") != nil })
            #expect(s.app.adjust("rotation-slider", to: 2.25) != nil)
            #expect(s.app.wait { (self.rotation(dir)?["degrees"] as? Double).map { abs($0 - 2.25) < 0.06 } ?? false })
        }
        let again = try launch(archive: dir); defer { again.close() }
        let restored = again.app.wait(timeout: 20) {
            guard let value = again.app.number("rotation-slider") else { return false }
            return abs(value - 2.25) < 0.06
        }
        let shown = again.app.number("rotation-slider")
        #expect(restored, "Nach dem Neustart steht der Regler auf \(String(describing: shown))")
        #expect(again.app.wait { again.app.string("thumbnail-strip") == "1" })
    }

    @Test func severalScansProduceThumbnails() throws {
        let s = try launch(); defer { s.close(); try? FileManager.default.removeItem(at: s.dir) }
        for n in 1...3 {
            #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
            scanOnce(s, expecting: n)
        }
        #expect(s.app.wait { s.app.string("thumbnail-strip") == "3" }, "Miniaturen: \(s.app.string("thumbnail-strip") ?? "keine Leiste")")
        #expect(originals(s.dir).count == 3)
    }
}
