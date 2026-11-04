import ApplicationServices
import Foundation
import Testing

/// Mehrere Serien an der echten App: neu oder fortsetzen, benennen, durchblättern, löschen.
/// Läuft nur mit `SCANUTIL_UI_TESTS=1`, im Hintergrund wie die anderen Oberflächentests.
@Suite("Oberfläche: Serien verwalten", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SCANUTIL_UI_TESTS"] != nil))
struct SerienVerwaltungOberflaechenTests {
    private func launch(mode: String = "document") throws -> UISession {
        let s = try UISession.launch(mode: mode)
        #expect(s.app.wait { s.app.string("status-text")?.hasPrefix("Bereit") == true }, "App wurde nicht bereit")
        return s
    }

    /// Nimmt die erste Serie mit `scans` Aufnahmen auf und beendet sie. Ohne vorhandene Serie fragt kein Dialog.
    private func recordFirstSeries(_ s: UISession, scans: Int) {
        #expect(s.app.press("series-start-button"))
        #expect(s.app.wait { s.app.element("series-page-count") != nil })
        for n in 1...scans {
            #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
            #expect(s.app.press("scan-button"))
            #expect(s.app.wait { s.originals.count == n }, "Original \(n) fehlt")
        }
        #expect(s.app.wait { s.pages.count == scans })
        #expect(s.app.press("series-end-button"))
        #expect(s.app.wait { s.app.element("series-start-button") != nil })
    }

    private func openSheet(_ s: UISession) {
        #expect(s.app.wait { s.app.isEnabled("series-start-button") == true })
        #expect(s.app.press("series-start-button"))
        #expect(s.app.wait { s.app.element("start-series-sheet") != nil }, "Der Dialog „neu oder fortsetzen?“ erscheint nicht")
    }

    // MARK: Beginnen

    @Test func theFirstSeriesStartsAtOnceWithoutAQuestion() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.press("series-start-button"))
        #expect(s.app.wait { s.app.element("series-page-count") != nil })
        #expect(s.app.element("start-series-sheet") == nil, "Ohne vorhandene Serie gibt es nichts zu fragen")
    }

    @Test func withExistingSeriesAnAskDialogAppearsAndCancelStartsNothing() throws {
        let s = try launch(); defer { s.close() }
        recordFirstSeries(s, scans: 1)
        openSheet(s)
        #expect(s.app.element("series-name-field") != nil && s.app.element("series-sheet-confirm") != nil)
        #expect(s.app.press("series-sheet-cancel"))
        #expect(s.app.wait { s.app.element("start-series-sheet") == nil })
        #expect(s.app.element("series-page-count") == nil, "Abbrechen darf keine Serie beginnen")
        #expect(s.documentFiles.count == 1)
    }

    @Test func aNewSeriesCanBeNamedInTheDialog() throws {
        let s = try launch(); defer { s.close() }
        recordFirstSeries(s, scans: 1)
        openSheet(s)
        #expect(s.app.type("Sagenbuch des Landes Wursten", into: "series-name-field"), "Namensfeld nicht gefunden")
        #expect(s.app.press("series-sheet-confirm"))
        #expect(s.app.wait { s.app.element("series-page-count") != nil }, "Die neue Serie begann nicht")
        #expect(s.app.string("series-page-count") == "0 Seiten", "Neu heißt: leer")
        #expect(s.app.wait { s.documentFiles.count == 2 })
        #expect(s.documentTitles.contains("Sagenbuch des Landes Wursten"), "Titel: \(s.documentTitles)")
    }

    @Test func resumingInTheDialogContinuesTheOldSeries() throws {
        let s = try launch(); defer { s.close() }
        recordFirstSeries(s, scans: 2)
        let before = s.documentFiles.map(\.lastPathComponent)
        openSheet(s)
        #expect(s.app.pressChild(of: "start-mode-picker", titled: "Fortsetzen"), "Das Segment „Fortsetzen“ ließ sich nicht drücken")
        #expect(s.app.wait { s.app.element("resume-picker") != nil }, "Die Auswahl der Serie erscheint nicht")
        #expect(s.app.press("series-sheet-confirm"))
        #expect(s.app.wait(timeout: 20) { s.app.string("series-page-count") == "2 Seiten" }, "Die Serie wurde nicht mit ihren Seiten fortgesetzt: \(s.app.string("series-page-count") ?? "keiner")")
        #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == 3 })
        #expect(s.app.wait { s.app.string("series-page-count") == "3 Seiten" })
        #expect(s.app.wait { s.pages.count == 3 }, "Die dritte Seite steht nicht im alten Dokument")
        #expect(s.documentFiles.map(\.lastPathComponent) == before, "Es darf kein zweites Dokument entstehen")
    }

    // MARK: Liste, Ansehen, Benennen, Löschen

    @Test func theListShowsEverySeriesAndOpeningOneShowsItsScans() throws {
        let s = try launch(); defer { s.close() }
        recordFirstSeries(s, scans: 2)
        openSheet(s)
        #expect(s.app.press("series-sheet-confirm"))                      // eine zweite, leere Serie
        #expect(s.app.wait { s.app.element("series-page-count") != nil })
        #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == 3 })
        #expect(s.app.wait { s.app.string("series-page-count") == "1 Seite" }, "Die Seite kam nicht in die Serie")
        #expect(s.app.press("series-end-button"))
        #expect(s.app.wait { s.app.element("series-start-button") != nil })

        #expect(s.app.string("series-list-button") == "2", "Zwei Serien: \(s.app.string("series-list-button") ?? "?")")
        #expect(s.app.press("series-list-button"))
        #expect(s.app.wait { s.app.element("series-list-view") != nil })
        #expect(s.app.wait { s.app.elements("series-row").count == 2 }, "Zeilen: \(s.app.elements("series-row").count)")

        // Die ältere Serie ansehen: ihre zwei Scans erscheinen in der Miniaturleiste.
        let labels = s.app.labels("series-row")
        #expect(labels.contains { $0.hasSuffix("2 Seiten") } && labels.contains { $0.hasSuffix("1 Seiten") }, "Zeilen: \(labels)")
        let olderRow = try #require(s.app.elements("series-row").enumerated().first { labels[$0.offset].hasSuffix("2 Seiten") }?.element)
        let open = try #require(s.app.find(olderRow) { AppDriver.string($0, kAXIdentifierAttribute) == "series-open-button" })
        #expect(AXUIElementPerformAction(open, kAXPressAction as CFString) == .success)
        #expect(s.app.wait(timeout: 20) { s.app.element("opened-document-label") != nil }, "Die Serie wurde nicht geöffnet")
        #expect(s.app.wait { s.app.string("thumbnail-strip") == "2" }, "Miniaturen: \(s.app.string("thumbnail-strip") ?? "keine")")
        #expect(s.app.string("opened-document-label")?.contains("2 Seiten") == true)
    }

    @Test func aSeriesCanBeRenamedFromTheList() throws {
        let s = try launch(); defer { s.close() }
        recordFirstSeries(s, scans: 1)
        #expect(s.app.press("series-list-button"))
        #expect(s.app.wait { s.app.element("series-list-view") != nil })
        #expect(s.app.press("series-menu"))
        #expect(s.app.wait { s.app.element("series-rename-button") != nil }, "Die Aktion „Umbenennen“ fehlt")
        #expect(s.app.press("series-rename-button"))
        #expect(s.app.wait { s.app.element("series-rename-field") != nil })
        // Das Feld enthält den alten Namen: erst alles auswählen (Befehl-A), dann tippen.
        #expect(s.app.type("Chronik", into: "series-rename-field"))
        #expect(s.app.press("series-rename-ok"))
        #expect(s.app.wait { s.documentTitles.contains { $0.hasSuffix("Chronik") } }, "Titel auf der Platte: \(s.documentTitles)")
    }

    @Test func deletingAsksFirstAndKeepsTheOriginals() throws {
        let s = try launch(); defer { s.close() }
        recordFirstSeries(s, scans: 2)
        #expect(s.documentFiles.count == 1 && s.originals.count == 2)
        #expect(s.app.press("series-list-button"))
        #expect(s.app.wait { s.app.element("series-list-view") != nil })
        #expect(s.app.press("series-menu"))
        #expect(s.app.wait { s.app.element("series-delete-button") != nil }, "Die Aktion „Nur die Serie löschen …“ fehlt")
        #expect(s.app.press("series-delete-button"))

        // Erst die Rückfrage: noch ist nichts gelöscht. Abbrechen lässt alles, wie es war.
        #expect(s.app.wait(timeout: 10) { s.app.hasButton(titled: "Abbrechen") && s.app.hasButton(titled: "Löschen") }, "Keine Rückfrage vor dem Löschen")
        #expect(s.documentFiles.count == 1, "Vor der Bestätigung darf nichts gelöscht sein")
        // Der Rückgabewert von AXPress taugt bei einer Rückfrage nicht (sie schließt sich dabei): Es zählt die Wirkung.
        s.app.pressButton(titled: "Abbrechen")
        #expect(s.app.wait { !s.app.hasButton(titled: "Löschen") })
        #expect(s.documentFiles.count == 1)

        #expect(s.app.press("series-menu"))
        #expect(s.app.wait { s.app.element("series-delete-button") != nil })
        #expect(s.app.press("series-delete-button"))
        #expect(s.app.wait(timeout: 10) { s.app.hasButton(titled: "Löschen") })
        s.app.pressButton(titled: "Löschen")
        #expect(s.app.wait(timeout: 10) { s.documentFiles.isEmpty }, "Die Serie wurde nicht gelöscht")
        #expect(s.originals.count == 2, "Die Originale müssen bleiben")
        #expect(s.app.wait { s.app.elements("series-row").isEmpty })
    }

    @Test func deletingASeriesCanBeUndoneFromTheBarAtTheBottom() throws {
        let s = try launch(); defer { s.close() }
        recordFirstSeries(s, scans: 1)
        #expect(s.app.press("series-list-button"))
        #expect(s.app.wait { s.app.element("series-list-view") != nil })
        #expect(s.app.press("series-menu"))
        #expect(s.app.wait { s.app.element("series-delete-button") != nil })
        #expect(s.app.press("series-delete-button"))
        #expect(s.app.wait { s.app.element("series-delete-confirm") != nil }, "Die Rückfrage in der Zeile fehlt")
        #expect(s.app.press("series-delete-confirm"))
        #expect(s.app.wait(timeout: 10) { s.documentFiles.isEmpty }, "Die Serie wurde nicht gelöscht")
        #expect(s.app.wait { s.app.element("undo-delete-button") != nil }, "Kein „Rückgängig“ nach dem Löschen")
        #expect(s.app.press("undo-delete-button"))
        #expect(s.app.wait(timeout: 10) { s.documentFiles.count == 1 }, "Die Serie kam nicht zurück")
        #expect(s.app.wait { s.app.elements("series-row").count == 1 })
        #expect(s.app.wait { s.app.element("undo-delete-button") == nil })
    }

    @Test func deletingAScanAsksFirstAndRemovesItFromTheSeries() throws {
        // Die Tests löschen endgültig (SCANUTIL_NO_TRASH): Die Scans landen nicht im Papierkorb des Entwicklers.
        let s = try launch(); defer { s.close() }
        #expect(s.app.press("series-start-button"))
        #expect(s.app.wait { s.app.element("series-page-count") != nil })
        for n in 1...2 {
            #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
            #expect(s.app.press("scan-button"))
            #expect(s.app.wait { s.originals.count == n })
        }
        #expect(s.app.wait { s.pages.count == 2 && s.app.string("series-page-count") == "2 Seiten" })
        #expect(s.app.wait(timeout: 30) { s.app.element("scan-delete-button") != nil }, "Die Scanansicht hat keinen Löschen-Knopf")

        // Erst die Rückfrage: nichts ist gelöscht. Abbrechen lässt alles.
        s.app.pressOpeningDialog("scan-delete-button")
        #expect(s.app.wait(timeout: 10) { s.app.hasButton(titled: "Abbrechen") && s.app.hasButton(titled: "Endgültig löschen") }, "Keine Rückfrage")
        #expect(s.originals.count == 2 && s.pages.count == 2, "Vor der Bestätigung darf nichts weg sein")
        s.app.pressButton(titled: "Abbrechen")
        #expect(s.app.wait { !s.app.hasButton(titled: "Endgültig löschen") })
        #expect(s.originals.count == 2)

        s.app.pressOpeningDialog("scan-delete-button")
        #expect(s.app.wait(timeout: 10) { s.app.hasButton(titled: "Endgültig löschen") })
        s.app.pressButton(titled: "Endgültig löschen")
        #expect(s.app.wait(timeout: 10) { s.originals.count == 1 }, "Das Original wurde nicht gelöscht")
        #expect(s.app.wait { s.app.string("series-page-count") == "1 Seite" }, "Zähler: \(s.app.string("series-page-count") ?? "keiner")")
        #expect(s.app.wait { s.pages.count == 1 }, "Die Seite steht noch in der Serie")
        #expect(s.app.wait { s.app.string("thumbnail-strip") == "1" })
        #expect(s.correctionFiles.count <= 1)
    }

    @Test func deletingASeriesWithItsScansFromTheListLeavesNothingBehind() throws {
        let s = try launch(); defer { s.close() }
        recordFirstSeries(s, scans: 2)
        #expect(s.originals.count == 2 && s.documentFiles.count == 1)
        #expect(s.app.press("series-list-button"))
        #expect(s.app.wait { s.app.element("series-list-view") != nil })
        #expect(s.app.press("series-menu"))
        #expect(s.app.wait { s.app.element("series-delete-scans-button") != nil }, "Die Aktion fehlt")
        #expect(s.app.press("series-delete-scans-button"))
        #expect(s.app.wait(timeout: 10) { s.app.hasButton(titled: "Serie und Scans endgültig löschen") }, "Keine Rückfrage")
        #expect(s.originals.count == 2, "Vor der Bestätigung bleibt alles")
        s.app.pressButton(titled: "Serie und Scans endgültig löschen")
        #expect(s.app.wait(timeout: 10) { s.documentFiles.isEmpty && s.originals.isEmpty }, "Serie und Scans sind nicht beide gelöscht")
        #expect(s.app.wait { s.app.elements("series-row").isEmpty })
    }
}
