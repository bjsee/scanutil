import ApplicationServices
import Foundation
import Testing

/// Der Scanner wird erst nach dem Start der App eingeschaltet: Sie muss ihn ohne Neustart finden.
/// Testmodus `document-late`: der Scanner erscheint vier Sekunden nach dem Start. Läuft nur mit `SCANUTIL_UI_TESTS=1`.
@Suite("Oberfläche: Verbindung", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SCANUTIL_UI_TESTS"] != nil))
struct VerbindungOberflaechenTests {
    @Test func appStartedBeforeTheScannerFindsItWithoutARestart() throws {
        let s = try UISession.launch(mode: "document-late"); defer { s.close() }
        // Zuerst ist kein Scanner da: Hinweis und Suche sind zu sehen, scannen geht nicht.
        #expect(s.app.wait { s.app.string("status-text") != nil }, "Die App zeigt keinen Status")
        #expect(s.app.string("status-text")?.hasPrefix("Bereit") == false, "Status schon bereit: \(s.app.string("status-text") ?? "")")
        #expect(s.app.wait { s.app.element("search-status") != nil }, "Keine Anzeige, dass die App weitersucht")
        #expect(s.app.element("reconnect-button") != nil)
        #expect(s.app.isEnabled("scan-button") == false, "Scannen ist ohne Scanner möglich")

        // Nach dem Auftauchen verbindet sie sich von selbst, ohne dass jemand etwas anfasst.
        let ready = s.app.wait(timeout: 30) { s.app.string("status-text") == "Bereit: Mock-Scanner" }
        #expect(ready, "Status nach 30 s: \(s.app.string("status-text") ?? "keiner")")
        #expect(s.app.wait { s.app.element("search-status") == nil }, "Die Suchanzeige bleibt stehen")
        #expect(s.app.wait { s.app.isEnabled("scan-button") == true })

        // Und funktioniert danach wie gewohnt.
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == 1 }, "Nach der späten Verbindung ließ sich nicht scannen")
    }

    @Test func theLogShowsTheErrorOnceAndThenTheConnection() throws {
        let s = try UISession.launch(mode: "document-late"); defer { s.close() }
        #expect(s.app.wait(timeout: 30) { s.app.string("status-text") == "Bereit: Mock-Scanner" })
        #expect(s.app.press("log-button"))
        #expect(s.app.wait { s.app.element("log-view") != nil })
        let rows = s.app.labels("log-row")
        // Die Suche lief mehrere Sekunden mit Versuchen im Zwei-Sekunden-Takt: der Fehler steht trotzdem nur einmal da.
        #expect(rows.filter { $0.hasPrefix("Fehler:") }.count == 1, "Zeilen: \(rows)")
        #expect(rows.first?.hasPrefix("Hinweis: Verbunden mit Mock-Scanner") == true, "Zeilen: \(rows)")
    }

    @Test func searchNowButtonIsHarmlessWhileTheScannerIsStillAbsent() throws {
        let s = try UISession.launch(mode: "document-late"); defer { s.close() }
        #expect(s.app.wait { s.app.element("reconnect-button") != nil })
        #expect(s.app.press("reconnect-button"))
        // Die App bleibt in der Suche und stürzt nicht ab; später verbindet sie sich trotzdem.
        #expect(s.app.string("status-text")?.hasPrefix("Bereit") == false)
        #expect(s.app.wait(timeout: 30) { s.app.string("status-text") == "Bereit: Mock-Scanner" })
    }

    // MARK: Verlust im laufenden Betrieb

    @Test func unpluggingDuringOperationShowsTheLossAndReconnectsOnItsOwn() throws {
        // Modus `document-unplug`: der Scanner wird 5 s nach dem Verbinden abgezogen und kommt 3 s später wieder.
        let s = try UISession.launch(mode: "document-unplug"); defer { s.close() }
        #expect(s.app.wait { s.app.string("status-text") == "Bereit: Mock-Scanner" }, "Nicht bereit: \(s.app.string("status-text") ?? "")")
        #expect(s.app.isEnabled("scan-button") == true)

        // Das Abziehen wird bemerkt: Statuszeile und Suchanzeige, Scannen gesperrt.
        #expect(s.app.wait(timeout: 20) { s.app.string("status-text") == "Suche Scanner …" }, "Status: \(s.app.string("status-text") ?? "keiner")")
        #expect(s.app.wait { s.app.element("search-status") != nil }, "Keine Suchanzeige nach dem Verlust")
        #expect(s.app.isEnabled("scan-button") == false, "Scannen ist ohne Scanner möglich")

        // Der Scanner kommt wieder: die App verbindet sich ohne Zutun und scannt danach.
        #expect(s.app.wait(timeout: 30) { s.app.string("status-text") == "Bereit: Mock-Scanner" }, "Status: \(s.app.string("status-text") ?? "keiner")")
        #expect(s.app.wait { s.app.element("search-status") == nil })
        #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == 1 }, "Nach dem Wiederverbinden ließ sich nicht scannen")

        // Das Protokoll nennt den Verlust genau einmal.
        #expect(s.app.press("log-button"))
        #expect(s.app.wait { s.app.element("log-view") != nil })
        let rows = s.app.labels("log-row")
        #expect(rows.filter { $0.contains("Verbindung zum Scanner ging verloren") }.count == 1, "Zeilen: \(rows)")
        #expect(rows.filter { $0.hasPrefix("Hinweis: Verbunden mit Mock-Scanner") }.count == 2, "Zwei Verbindungen erwartet: \(rows)")
    }

    @Test func aSeriesContinuesInTheSameDocumentAfterAnUnplug() throws {
        let s = try UISession.launch(mode: "document-unplug"); defer { s.close() }
        #expect(s.app.wait { s.app.string("status-text") == "Bereit: Mock-Scanner" })
        #expect(s.app.press("series-start-button"))
        #expect(s.app.wait { s.app.element("series-page-count") != nil })
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == 1 })
        #expect(s.app.wait { s.app.string("series-page-count") == "1 Seite" })

        #expect(s.app.wait(timeout: 20) { s.app.string("status-text") == "Suche Scanner …" })
        // Die Serie bleibt sichtbar, die Seite erhalten.
        #expect(s.app.element("series-page-count") != nil, "Die Serie wurde beim Verlust beendet")
        #expect(s.app.string("series-page-count") == "1 Seite")

        #expect(s.app.wait(timeout: 30) { s.app.string("status-text") == "Bereit: Mock-Scanner" })
        #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == 2 })
        #expect(s.app.wait { s.app.string("series-page-count") == "2 Seiten" }, "Zähler: \(s.app.string("series-page-count") ?? "keiner")")
        #expect(s.documentFiles.count == 1, "Es entstand ein zweites Dokument")
        #expect(s.app.wait { s.pages.count == 2 })
    }
}
