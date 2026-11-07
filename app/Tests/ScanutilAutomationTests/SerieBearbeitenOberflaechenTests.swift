import ApplicationServices
import Foundation
import Testing

/// „Serie bearbeiten“ an der echten App: Fenster öffnen, Unsicheres finden, filtern, als geprüft abhaken.
/// Läuft nur mit `SCANUTIL_UI_TESTS=1`, im Hintergrund wie die anderen Oberflächentests.
@Suite("Oberfläche: Serie bearbeiten", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SCANUTIL_UI_TESTS"] != nil))
struct SerieBearbeitenOberflaechenTests {
    /// Rauschen: Die Automatik ist bei jeder Aufnahme unsicher, so gibt es etwas zu prüfen.
    private func recordedSeries(scans: Int) throws -> UISession {
        let s = try UISession.launch(mode: "noise")
        #expect(s.app.wait { s.app.string("status-text")?.hasPrefix("Bereit") == true }, "App wurde nicht bereit")
        #expect(s.app.press("series-start-button"))
        #expect(s.app.wait { s.app.element("series-page-count") != nil })
        for n in 1...scans {
            #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
            #expect(s.app.press("scan-button"))
            #expect(s.app.wait { s.originals.count == n }, "Original \(n) fehlt")
        }
        // Die Analyse schreibt ihre Zusammenfassung an die Seiten: darauf warten, sonst gälte die Seite noch als „nicht ausgewertet“.
        #expect(s.app.wait(timeout: 30) { s.pages.count == scans && s.pages.allSatisfy { $0["analysis"] != nil } }, "Analyse fehlt")
        #expect(s.app.press("series-end-button"))
        #expect(s.app.wait { s.app.element("series-start-button") != nil })
        return s
    }

    private func openEditor(_ s: UISession) {
        #expect(s.app.press("series-list-button"))
        #expect(s.app.wait { s.app.element("series-list-view") != nil })
        #expect(s.app.wait { s.app.element("series-edit-button") != nil })
        #expect(s.app.press("series-edit-button"))
        #expect(s.app.wait(timeout: 15) { s.app.element("editor-grid") != nil }, "Die Seite „Serie bearbeiten“ öffnet sich nicht")
    }

    @Test func theEditorShowsEveryPageAndMarksTheUnsureOnes() throws {
        let s = try recordedSeries(scans: 2); defer { s.close() }
        #expect(s.app.windows.count == 1)
        openEditor(s)
        #expect(s.app.windows.count == 1, "Der Editor ist eine Seite im Fenster, kein zweites Fenster")
        #expect(s.app.wait { s.app.element("editor-page-1") != nil && s.app.element("editor-page-2") != nil }, "Nicht alle Seiten im Raster")
        for n in 1...2 {
            let state = s.app.string("editor-page-\(n)")
            #expect(state == "prüfen" || state == "problem", "Seite \(n) zeigt \(state ?? "nichts")")
        }
        #expect(s.app.element("editor-filter-uncertain") != nil)
        #expect(s.app.string("editor-filter-uncertain") == "2", "Zahl am Filter: \(s.app.string("editor-filter-uncertain") ?? "keine")")
    }

    @Test func reviewingAPageSavesItAndTakesItOutOfTheUncertainFilter() throws {
        let s = try recordedSeries(scans: 2); defer { s.close() }
        openEditor(s)
        #expect(s.app.wait { s.app.element("editor-page-1") != nil })
        #expect(s.app.press("editor-page-1"))
        #expect(s.app.wait { s.app.element("editor-reviewed") != nil })
        #expect(s.app.press("editor-reviewed"))
        #expect(s.app.wait(timeout: 10) { s.pages.first?["reviewedKey"] != nil }, "Geprüft steht nicht im Dokument")
        #expect(s.app.wait { s.app.string("editor-page-1") == "geprüft" }, "Seite zeigt \(s.app.string("editor-page-1") ?? "nichts")")
        #expect(s.app.wait { s.app.string("editor-filter-uncertain") == "1" })

        #expect(s.app.press("editor-filter-uncertain"))
        #expect(s.app.wait { s.app.element("editor-page-1") == nil && s.app.element("editor-page-2") != nil }, "Der Filter blendet die geprüfte Seite nicht aus")
        #expect(s.app.press("editor-filter-all"))
        #expect(s.app.wait { s.app.element("editor-page-1") != nil })
    }

    @Test func changingTheRotationInTheEditorIsSavedAsManualAndReopensThePage() throws {
        let s = try recordedSeries(scans: 1); defer { s.close() }
        openEditor(s)
        #expect(s.app.wait { s.app.element("editor-reviewed") != nil || s.app.element("editor-page-1") != nil })
        #expect(s.app.press("editor-page-1"))
        #expect(s.app.wait { s.app.element("editor-rotation") != nil })
        #expect(s.app.press("editor-reviewed"))
        #expect(s.app.wait(timeout: 10) { s.pages.first?["reviewedKey"] != nil })
        #expect(s.app.adjust("editor-rotation", to: 4) != nil)
        #expect(s.app.wait(timeout: 10) { s.rotation(ofPage: 0).map { abs($0.degrees - 4) < 0.1 && $0.source == "manual" } ?? false }, "Winkel nicht gespeichert")
        #expect(s.app.wait { s.app.string("editor-page-1") != "geprüft" }, "Nach der Änderung muss die Seite wieder offen sein")
    }

    @Test func theSelectedPageShowsTheOriginalWithItsCropAndCanSwitchToTheResult() throws {
        let s = try recordedSeries(scans: 1); defer { s.close() }
        openEditor(s)
        #expect(s.app.wait { s.app.element("editor-page-1") != nil })
        #expect(s.app.press("editor-page-1"))
        #expect(s.app.wait(timeout: 15) { s.app.element("editor-preview") != nil }, "Keine große Ansicht der gewählten Seite")
        #expect(s.app.wait(timeout: 15) { s.app.element("editor-preview-zoom-in") != nil }, "Die große Ansicht lässt sich nicht zoomen")
        #expect(s.app.element("editor-preview-mode") != nil)
        #expect(s.app.element("editor-card-size") != nil, "Der Größenregler fehlt")
    }

    @Test func cropAndRotationHaveVisibleControlsThatChangeThePage() throws {
        let s = try recordedSeries(scans: 1); defer { s.close() }
        openEditor(s)
        #expect(s.app.wait { s.app.element("editor-page-1") != nil })
        #expect(s.app.press("editor-page-1"))
        #expect(s.app.wait { s.app.element("editor-crop-edit") != nil && s.app.element("editor-rotation-plus") != nil }, "Werkzeuge fehlen")

        // Drehung in Schritten von 0,1°.
        #expect(s.app.press("editor-rotation-zero"))
        #expect(s.app.wait(timeout: 10) { s.rotation(ofPage: 0).map { $0.degrees == 0 && $0.source == "manual" } ?? false })
        #expect(s.app.press("editor-rotation-plus"))
        #expect(s.app.press("editor-rotation-plus"))
        #expect(s.app.wait(timeout: 10) { s.rotation(ofPage: 0).map { abs($0.degrees - 0.2) < 0.01 } ?? false }, "Schritte: \(String(describing: s.rotation(ofPage: 0)))")

        // „Rahmen ziehen“ zeigt den Rahmen mit vier Ecken.
        #expect(s.app.press("editor-crop-edit"))
        #expect(s.app.wait(timeout: 15) { s.app.element("editor-crop-editor") != nil }, "Kein Rahmen zum Ziehen")
        for corner in ["topLeft", "topRight", "bottomRight", "bottomLeft"] {
            #expect(s.app.wait { s.app.element("editor-crop-handle-\(corner)") != nil }, "Ecke \(corner) fehlt")
        }
        // „Ganzes Bild“ setzt den Zuschnitt von Hand.
        #expect(s.app.press("editor-crop-half"))
        #expect(s.app.wait(timeout: 10) {
            ((s.pages.first?["corrections"] as? [String: Any])?["crop"] as? [String: Any])?["source"] as? String == "manual"
        }, "Zuschnitt nicht als manuell gespeichert")
    }

    @Test func theSidebarListsTheSeriesAndSwitchesBetweenThem() throws {
        let s = try recordedSeries(scans: 1); defer { s.close() }
        // Eine zweite Serie, damit es etwas zu wechseln gibt.
        #expect(s.app.press("series-start-button"))
        #expect(s.app.wait { s.app.element("start-series-sheet") != nil })
        #expect(s.app.type("Zweite", into: "series-name-field"))
        #expect(s.app.press("series-sheet-confirm"))
        #expect(s.app.wait { s.app.element("series-page-count") != nil })
        #expect(s.app.press("series-end-button"))
        #expect(s.app.wait { s.app.elements("nav-series-item").count == 2 }, "Serien in der Seitenleiste: \(s.app.elements("nav-series-item").count)")
        let labels = s.app.labels("nav-series-item")
        #expect(labels.count == 2)

        // Ein Klick öffnet die Serie zum Bearbeiten, ein zweiter wechselt.
        let items = s.app.elements("nav-series-item")
        for item in items {
            #expect(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success)
            #expect(s.app.wait { s.app.element("editor-grid") != nil || s.app.element("editor-empty") != nil })
        }
        #expect(s.app.wait { s.app.element("editor-title") != nil })

        // Ein- und Ausklappen.
        #expect(s.app.press("nav-series-toggle"))
        #expect(s.app.wait { s.app.elements("nav-series-item").isEmpty }, "Die Liste klappt nicht zu")
        #expect(s.app.press("nav-series-toggle"))
        #expect(s.app.wait { s.app.elements("nav-series-item").count == 2 })
    }

    @Test func aSeriesIsRenamedInTheEditorAndTheNameAndDateShowUpInTheSidebar() throws {
        let s = try recordedSeries(scans: 1); defer { s.close() }
        openEditor(s)
        #expect(s.app.wait { s.app.element("editor-rename") != nil })
        #expect(s.app.press("editor-rename"))
        #expect(s.app.wait { s.app.element("editor-title-field") != nil })
        #expect(s.app.type(" Chronik", into: "editor-title-field"))
        #expect(s.app.press("editor-title-ok"))
        #expect(s.app.wait(timeout: 10) { s.documentTitles.contains { $0.hasSuffix("Chronik") } }, "Titel auf der Platte: \(s.documentTitles)")
        // Der Name steht in der Beschreibung des Eintrags, der Zeitpunkt im Wert.
        func names() -> [String] { s.app.elements("nav-series-item").map { AppDriver.string($0, kAXDescriptionAttribute) ?? AppDriver.string($0, kAXTitleAttribute) ?? "" } }
        #expect(s.app.wait { names().contains { $0.hasSuffix("Chronik") } }, "Seitenleiste: \(names())")
        #expect(s.app.labels("nav-series-item").contains { $0.hasPrefix("zuletzt bearbeitet") }, "Zeitpunkt fehlt: \(s.app.labels("nav-series-item"))")
        #expect(s.app.string("editor-summary")?.contains("zuletzt bearbeitet") == true, "Datum fehlt: \(s.app.string("editor-summary") ?? "-")")
        #expect(s.document?["modifiedAt"] != nil, "Die letzte Bearbeitung steht nicht im Dokument")
    }
}
