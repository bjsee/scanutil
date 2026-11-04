import AppKit
import ApplicationServices
import Foundation
import PDFKit
import Testing

/// Serie, Auto-Auslösung, Buchmodus, Protokoll und PDF-Export an der echten App.
/// Läuft nur mit `SCANUTIL_UI_TESTS=1`, siehe `OberflaechenTests`.
@Suite("Oberfläche: Serie und Meldungen", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SCANUTIL_UI_TESTS"] != nil))
struct SerieOberflaechenTests {
    private func launch(mode: String = "document") throws -> UISession {
        let s = try UISession.launch(mode: mode)
        let ready = s.app.wait { s.app.string("status-text")?.hasPrefix("Bereit") == true }
        #expect(ready, "App wurde nicht bereit")
        return s
    }

    private func startSeries(_ s: UISession, book: Bool = false) {
        if book {
            #expect(s.app.press("book-mode-toggle"), "Buch-Schalter nicht gefunden")
        }
        #expect(s.app.press("series-start-button"), "Serie beginnen nicht gefunden")
        #expect(s.app.wait { s.app.element("series-page-count") != nil }, "Serienleiste erscheint nicht")
    }

    /// Scannt über die Schaltfläche und wartet, bis das Original auf der Platte liegt.
    private func scan(_ s: UISession, expecting count: Int) {
        #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == count }, "Original \(count) wurde nicht archiviert")
    }

    private func pageCount(_ s: UISession) -> String? { s.app.string("series-page-count") }

    /// Der Wert des Meldungen-Knopfs, etwa „2 neu, 3 insgesamt“.
    private func logValue(_ s: UISession) -> String? { s.app.string("log-button") }

    private func unseen(_ s: UISession) -> Int? {
        logValue(s).flatMap { $0.split(separator: " ").first }.flatMap { Int($0) }
    }

    // MARK: Serie

    @Test func startingASeriesShowsTheBarAndSavesAnEmptyDocument() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.element("series-start-button") != nil)
        #expect(s.app.element("series-end-button") == nil)
        startSeries(s)
        #expect(pageCount(s) == "0 Seiten")
        #expect(s.app.element("series-start-button") == nil, "Beginnen bleibt sichtbar")
        #expect(s.app.element("series-end-button") != nil)
        #expect(s.app.wait { s.documentFiles.count == 1 }, "Dokument wurde nicht gespeichert")
        #expect(s.pages.isEmpty)
    }

    @Test func aScanInASeriesBecomesAPageOfTheSavedDocument() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s)
        // Im Modus „document“ flimmert die Vorschau dauernd, die Auto-Auslösung bleibt still: nur dieser Scan zählt.
        scan(s, expecting: 1)
        #expect(s.app.wait { pageCount(s) == "1 Seite" }, "Zähler: \(pageCount(s) ?? "keiner")")
        #expect(s.app.wait { s.pages.count == 1 }, "Seite steht nicht im Dokument")
        let scanID = s.originals.first?.deletingPathExtension().lastPathComponent
        #expect(s.pages.first?["scanID"] as? String == scanID?.uppercased() || s.pages.first?["scanID"] as? String == scanID,
                "Seite verweist auf \(String(describing: s.pages.first?["scanID"])), Original ist \(scanID ?? "?")")
        #expect(s.pages.first?["region"] as? String == "whole")
    }

    @Test func endingTheSeriesBringsBackTheStartButtonAndKeepsTheDocument() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s)
        scan(s, expecting: 1)
        #expect(s.app.wait { s.pages.count == 1 })
        #expect(s.app.press("series-end-button"))
        #expect(s.app.wait { s.app.element("series-start-button") != nil })
        #expect(s.app.element("series-page-count") == nil)
        #expect(s.documentFiles.count == 1, "Das Dokument muss bleiben")
        #expect(s.pages.count == 1)
    }

    @Test func spaceBarAddsAPageToTheSeries() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s)
        #expect(s.app.pressSpace())
        #expect(s.app.wait { s.originals.count == 1 })
        #expect(s.app.wait { s.pages.count == 1 }, "Leertaste hat keine Seite angehängt")
    }

    // MARK: Hände und Daumen

    private func handRemoval(_ json: [String: Any]?) -> (enabled: Bool, source: String, hasMask: Bool)? {
        guard let h = (json?["corrections"] as? [String: Any] ?? json)?["handRemoval"] as? [String: Any],
              let enabled = h["enabled"] as? Bool, let source = h["source"] as? String else { return nil }
        return (enabled, source, h["mask"] != nil)
    }

    @Test func aThumbInTheScanIsRemovedAndTheSwitchWorks() throws {
        let s = try launch(mode: "document-hands"); defer { s.close() }
        #expect(s.app.element("hands-toggle") == nil)
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == 1 })
        #expect(s.app.wait(timeout: 60) { s.app.element("hands-toggle") != nil }, "Der Daumen wurde nicht erkannt: kein Schalter")
        #expect(s.app.number("hands-toggle") == 1, "Sicher erkannt: wird angewendet")
        #expect(s.app.wait(timeout: 30) { handRemoval(s.corrections)?.hasMask == true && handRemoval(s.corrections)?.enabled == true })

        #expect(s.app.press("hands-toggle"))
        #expect(s.app.wait { s.app.number("hands-toggle") == 0 })
        #expect(s.app.wait { handRemoval(s.corrections).map { !$0.enabled && $0.source == "manual" && $0.hasMask } ?? false },
                "Der Schalter wurde nicht gespeichert: \(String(describing: handRemoval(s.corrections)))")
        #expect(s.app.press("hands-toggle"))
        #expect(s.app.wait { s.app.number("hands-toggle") == 1 })
    }

    @Test func bookPagesHaveTheirOwnHandSwitch() throws {
        let s = try launch(mode: "document-hands"); defer { s.close() }
        startSeries(s, book: true)
        scan(s, expecting: 1)
        #expect(s.app.wait(timeout: 60) { s.app.element("book-hands-links") != nil && s.app.element("book-hands-rechts") != nil },
                "Die Seiten haben keinen Schalter für die Hände")
        #expect(s.app.press("book-hands-links"))
        #expect(s.app.wait { s.app.number("book-hands-links") == 0 })
        #expect(s.app.wait { s.pages.count == 2 && handRemoval(s.pages[0])?.enabled == false })
        #expect(handRemoval(s.pages[1])?.enabled == true, "Die rechte Seite bleibt")
    }

    // MARK: Gespeicherte Dokumente

    @Test func anEndedSeriesCanStillBeExportedFromTheSeriesPage() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s)
        scan(s, expecting: 1)
        #expect(s.app.wait { pageCount(s) == "1 Seite" })
        #expect(s.app.press("series-end-button"))
        #expect(s.app.wait { s.app.element("series-start-button") != nil })
        // Nach dem Beenden führt der Weg zum PDF über die Seite Serien.
        #expect(s.app.element("series-export-button") == nil)
        #expect(s.app.press("series-list-button"))
        #expect(s.app.wait { s.app.element("series-list-view") != nil })
        #expect(s.app.press("series-menu"))
        #expect(s.app.wait { s.app.element("series-pdf-button") != nil }, "Nach dem Beenden gibt es keinen Weg zum PDF")
        #expect(s.app.press("series-pdf-button"))
        #expect(s.app.wait { s.app.element("export-run-button") != nil }, "Die Seite „PDF ausgeben“ öffnet sich nicht")
        #expect(s.app.press("export-run-button"))
        #expect(s.app.wait(timeout: 60) { !s.pdfs.isEmpty }, "Es wurde kein PDF geschrieben")
        let pdf = try #require(s.pdfs.first)
        #expect(s.app.wait(timeout: 30) { PDFDocument(url: pdf)?.pageCount == 1 })
        #expect(s.app.wait { s.app.element("export-reveal-button") != nil }, "Kein Link zum PDF")
    }

    // MARK: Ton

    @Test func theSoundSwitchIsInTheSeriesBarAndCanBeToggled() throws {
        // Die App läuft in den Tests stumm (`SCANUTIL_NO_SOUND`) und speichert keine Einstellungen.
        let s = try launch(); defer { s.close() }
        #expect(s.app.element("sound-toggle") == nil, "Der Tonschalter gehört in die Serienleiste")
        startSeries(s)
        #expect(s.app.wait { s.app.element("sound-toggle") != nil }, "Kein Tonschalter in der Serienleiste")
        #expect(s.app.number("sound-toggle") == 1, "Der Ton ist standardmäßig an")
        #expect(s.app.press("sound-toggle"))
        #expect(s.app.wait { s.app.number("sound-toggle") == 0 }, "Der Schalter ließ sich nicht ausschalten")
        // Aufnehmen geht ohne Ton genauso.
        scan(s, expecting: 1)
        #expect(s.app.wait { pageCount(s) == "1 Seite" })
        #expect(s.app.press("sound-toggle"))
        #expect(s.app.wait { s.app.number("sound-toggle") == 1 })
    }

    // MARK: Auto-Auslösung

    @Test func autoTriggerCapturesExactlyOnePageOnAStillPreview() throws {
        let s = try launch(mode: "document-still"); defer { s.close() }
        startSeries(s)
        // Ruhige Vorschau von Anfang an: nach etwa 0,8 s löst die App selbst aus.
        #expect(s.app.wait(timeout: 20) { s.originals.count == 1 }, "Die Auto-Auslösung hat nicht ausgelöst")
        #expect(s.app.wait { pageCount(s) == "1 Seite" })
        // Danach sperrt sie, bis Bewegung kommt: auch nach Sekunden bleibt es bei einer Seite.
        Thread.sleep(forTimeInterval: 4)
        #expect(s.originals.count == 1, "Dieselbe ruhende Seite wurde mehrfach aufgenommen: \(s.originals.count)")
        #expect(pageCount(s) == "1 Seite")
        #expect(s.pages.count == 1)
    }

    @Test func switchingAutoTriggerOffStopsSelfCaptureButKeepsManualScans() throws {
        let s = try launch(mode: "document-still"); defer { s.close() }
        startSeries(s)
        #expect(s.app.press("auto-trigger-toggle"), "Schalter nicht gefunden")   // vor Ablauf der 0,8 s Ruhe
        #expect(s.app.wait { s.app.element("series-phase") == nil }, "Ruheanzeige bleibt bei ausgeschalteter Automatik")
        Thread.sleep(forTimeInterval: 3.5)
        #expect(s.originals.isEmpty, "Es wurde trotz ausgeschalteter Automatik aufgenommen")
        scan(s, expecting: 1)
        #expect(s.app.wait { pageCount(s) == "1 Seite" })
        // Wieder einschalten bringt die Anzeige zurück.
        #expect(s.app.press("auto-trigger-toggle"))
        #expect(s.app.wait { s.app.element("series-phase") != nil }, "Anzeige kommt nach dem Einschalten nicht zurück")
    }

    @Test func phaseIndicatorIsShownWhileAutoTriggerIsOn() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s)
        #expect(s.app.wait { s.app.element("series-phase") != nil }, "Keine Anzeige der Auto-Auslösung")
        #expect(s.app.element("auto-trigger-toggle") != nil)
    }

    // MARK: Buchmodus

    @Test func bookModeCreatesALeftAndARightPageWithOwnControls() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s, book: true)
        scan(s, expecting: 1)
        #expect(s.app.wait { pageCount(s) == "2 Seiten" }, "Zähler: \(pageCount(s) ?? "keiner")")
        #expect(s.app.wait { s.pages.count == 2 })
        #expect(s.pages.compactMap { $0["region"] as? String } == ["left", "right"])
        #expect(s.pages.compactMap { $0["scanID"] as? String }.reduce(into: Set<String>()) { $0.insert($1) }.count == 1,
                "Beide Seiten gehören zu einem Original")

        #expect(s.app.wait(timeout: 20) { s.app.element("book-controls") != nil }, "Keine Seitenbedienung für die Doppelseite")
        #expect(s.app.element("book-page-left") != nil && s.app.element("book-page-right") != nil)
        #expect(s.app.element("book-rotation-slider-links") != nil && s.app.element("book-rotation-slider-rechts") != nil)
        // Das Einzelseiten-Bedienfeld ist für Doppelseiten nicht da.
        #expect(s.app.element("rotation-slider") == nil)
    }

    @Test func rotatingOneBookPageLeavesTheOtherUntouched() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s, book: true)
        scan(s, expecting: 1)
        #expect(s.app.wait(timeout: 20) { s.app.element("book-rotation-slider-links") != nil })
        // Erst die Automatik abwarten (sie setzt den Zuschnitt beider Seiten), sonst überschreibt sie den Handwert oder
        // ändert die rechte Seite nach meiner Messung.
        #expect(s.app.wait(timeout: 30) { s.hasCrop(ofPage: 0) && s.hasCrop(ofPage: 1) }, "Die Analyse der Doppelseite wurde nicht fertig")
        let rightBefore = s.rotation(ofPage: 1)

        let reached = s.app.adjust("book-rotation-slider-links", to: 4.0)
        #expect(reached.map { abs($0 - 4.0) < 0.06 } ?? false, "Regler erreichte \(String(describing: reached))")
        #expect(s.app.wait { s.rotation(ofPage: 0).map { abs($0.degrees - 4.0) < 0.06 && $0.source == "manual" } ?? false },
                "Linke Seite: \(String(describing: s.rotation(ofPage: 0)))")
        #expect(s.rotation(ofPage: 1)?.degrees == rightBefore?.degrees, "Die rechte Seite hat sich mitbewegt")
        #expect(s.rotation(ofPage: 1)?.source != "manual")
    }

    // MARK: Meldungen

    @Test func logButtonStartsWithTheConnectionNoteAndOpensTheList() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.wait { logValue(s) == "0 neu, 1 insgesamt" }, "Knopf zeigt \(logValue(s) ?? "nichts")")
        #expect(s.app.press("log-button"))
        #expect(s.app.wait { s.app.element("log-view") != nil }, "Protokoll öffnet sich nicht")
        let rows = s.app.labels("log-row")
        #expect(rows.count == 1, "Zeilen: \(rows)")
        #expect(rows.first?.hasPrefix("Hinweis: Verbunden mit Mock-Scanner") == true, "Zeile: \(rows.first ?? "keine")")
    }

    @Test func analysisWarningsRaiseTheBadgeAndAppearInTheList() throws {
        let s = try launch(mode: "noise"); defer { s.close() }
        #expect(unseen(s) == 0)
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait(timeout: 30) { (unseen(s) ?? 0) > 0 }, "Zähler bleibt bei \(logValue(s) ?? "nichts")")
        #expect(s.app.press("log-button"))
        #expect(s.app.wait { s.app.element("log-view") != nil })
        let rows = s.app.labels("log-row")
        #expect(rows.contains { $0.hasPrefix("Warnung:") }, "Keine Warnung in \(rows)")
        // Das Öffnen setzt den Zähler zurück.
        #expect(s.app.wait { unseen(s) == 0 }, "Zähler nach dem Öffnen: \(logValue(s) ?? "nichts")")
    }

    @Test func copyPutsTheLogOnTheClipboardAndClearEmptiesIt() throws {
        let s = try launch(mode: "noise"); defer { s.close() }
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait(timeout: 30) { (unseen(s) ?? 0) > 0 })
        #expect(s.app.press("log-button"))
        #expect(s.app.wait { s.app.element("log-copy-button") != nil })

        NSPasteboard.general.clearContents()
        #expect(s.app.press("log-copy-button"))
        let copied = s.app.wait { NSPasteboard.general.string(forType: .string)?.contains("WARNUNG") == true }
        #expect(copied, "Zwischenablage: \(NSPasteboard.general.string(forType: .string) ?? "leer")")
        #expect(NSPasteboard.general.string(forType: .string)?.contains("Verbunden mit Mock-Scanner") == true)

        #expect(s.app.press("log-clear-button"))
        #expect(s.app.wait { s.app.elements("log-row").isEmpty }, "Zeilen bleiben stehen")
        #expect(s.app.wait { logValue(s) == "0 neu, 0 insgesamt" }, "Knopf zeigt \(logValue(s) ?? "nichts")")
    }

    @Test func endingASeriesIsLogged() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s)
        #expect(s.app.press("series-end-button"))
        #expect(s.app.wait { s.app.element("series-start-button") != nil })
        #expect(s.app.press("log-button"))
        #expect(s.app.wait { s.app.element("log-view") != nil })
        let rows = s.app.labels("log-row")
        #expect(rows.contains { $0.contains("begonnen") }, "Zeilen: \(rows)")
        #expect(rows.contains { $0.contains("beendet") }, "Zeilen: \(rows)")
        // Neueste zuerst.
        #expect(rows.first?.contains("beendet") == true)
    }

    // MARK: Export

    @Test func exportIsDisabledWithoutPagesAndEnabledWithOne() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s)
        #expect(s.app.isEnabled("series-export-button") == false, "Export ohne Seiten ist aktiv")
        scan(s, expecting: 1)
        #expect(s.app.wait { s.app.isEnabled("series-export-button") == true }, "Export bleibt nach einer Seite gesperrt")
        #expect(s.app.press("series-export-button"))
        #expect(s.app.wait { s.app.element("export-run-button") != nil && s.app.element("export-ocr-toggle") != nil }, "Seite „PDF ausgeben“ unvollständig")
        #expect(s.app.isEnabled("export-run-button") == true)
    }

    @Test func exportFromTheExportPageWritesAPDFWithOnePagePerScan() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s)
        scan(s, expecting: 1)
        #expect(s.app.wait { pageCount(s) == "1 Seite" })
        scan(s, expecting: 2)
        #expect(s.app.wait { pageCount(s) == "2 Seiten" })

        #expect(s.app.wait { s.app.isEnabled("series-export-button") == true })
        #expect(s.app.press("series-export-button"))
        #expect(s.app.wait { s.app.element("export-run-button") != nil }, "Die Seite „PDF ausgeben“ öffnet sich nicht")
        #expect(s.app.press("export-run-button"))

        #expect(s.app.wait(timeout: 60) { !s.pdfs.isEmpty }, "Es wurde kein PDF geschrieben")
        let pdf = try #require(s.pdfs.first)
        #expect(pdf.lastPathComponent.hasPrefix("Serie"), "Dateiname: \(pdf.lastPathComponent)")
        #expect(s.app.wait(timeout: 30) { PDFDocument(url: pdf)?.pageCount == 2 }, "Seiten im PDF: \(PDFDocument(url: pdf)?.pageCount ?? -1)")
        #expect(s.app.wait { s.app.element("export-reveal-button") != nil }, "Kein Link zum PDF nach dem Export")

        // Der Bericht steht im Protokoll.
        #expect(s.app.press("log-button"))
        #expect(s.app.wait { s.app.element("log-view") != nil })
        #expect(s.app.labels("log-row").contains { $0.contains("PDF geschrieben: 2 Seite") }, "Zeilen: \(s.app.labels("log-row"))")
    }

    @Test func exportOfABookHasTwoPdfPagesPerScan() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s, book: true)
        scan(s, expecting: 1)
        #expect(s.app.wait { pageCount(s) == "2 Seiten" })
        #expect(s.app.press("series-export-button"))
        #expect(s.app.wait { s.app.element("export-run-button") != nil })
        #expect(s.app.press("export-run-button"))
        #expect(s.app.wait(timeout: 60) { !s.pdfs.isEmpty }, "Es wurde kein PDF geschrieben")
        let pdf = try #require(s.pdfs.first)
        #expect(s.app.wait(timeout: 30) { PDFDocument(url: pdf)?.pageCount == 2 }, "Seiten im PDF: \(PDFDocument(url: pdf)?.pageCount ?? -1)")
    }

    @Test func aSecondExportNeverOverwritesTheFirst() throws {
        let s = try launch(); defer { s.close() }
        startSeries(s)
        scan(s, expecting: 1)
        #expect(s.app.wait { pageCount(s) == "1 Seite" })
        #expect(s.app.press("series-export-button"))
        #expect(s.app.wait { s.app.element("export-run-button") != nil })
        #expect(s.app.press("export-run-button"))
        #expect(s.app.wait(timeout: 60) { s.pdfs.count == 1 })
        #expect(s.app.wait { s.app.isEnabled("export-run-button") == true })
        #expect(s.app.press("export-run-button"))
        #expect(s.app.wait(timeout: 60) { s.pdfs.count == 2 }, "Das zweite PDF überschrieb das erste: \(s.pdfs.map(\.lastPathComponent))")
    }
}
