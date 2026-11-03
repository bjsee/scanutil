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
        _ = s.app.press("series-menu")
        #expect(s.app.pressMenuItem(titled: "Bearbeiten …"), "Der Menüeintrag „Bearbeiten …“ fehlt")
        #expect(s.app.wait(timeout: 15) { s.app.element("editor-grid") != nil }, "Das Fenster „Serie bearbeiten“ ging nicht auf")
    }

    @Test func theEditorShowsEveryPageAndMarksTheUnsureOnes() throws {
        let s = try recordedSeries(scans: 2); defer { s.close() }
        #expect(s.app.windows.count == 1, "Der Editor darf nicht von selbst aufgehen und dem Hauptfenster den Fokus nehmen")
        openEditor(s)
        #expect(s.app.windows.count == 2)
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
}
