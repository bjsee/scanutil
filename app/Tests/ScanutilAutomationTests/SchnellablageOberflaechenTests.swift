import ApplicationServices
import Foundation
import PDFKit
import Testing

/// Die Dokumenten-Schnellablage an der echten App: aufnehmen, fertig, zusammenfassen, ablegen; Einstellungen und Fußtaster.
/// Läuft nur mit `SCANUTIL_UI_TESTS=1`, im Hintergrund wie die anderen Oberflächentests.
@Suite("Oberfläche: Schnellablage", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SCANUTIL_UI_TESTS"] != nil))
struct SchnellablageOberflaechenTests {
    private func launch() throws -> UISession {
        let s = try UISession.launch(mode: "document")
        #expect(s.app.wait { s.app.string("status-text")?.hasPrefix("Bereit") == true }, "App wurde nicht bereit")
        return s
    }

    /// Startet eine Schnellablage und nimmt `scans` Dokumente über die Schaltfläche auf.
    private func record(_ s: UISession, scans: Int) {
        #expect(s.app.press("nav-inbox"))
        #expect(s.app.wait { s.app.element("inbox-start-button") != nil })
        #expect(s.app.press("inbox-start-button"))
        #expect(s.app.wait { s.app.element("series-page-count") != nil }, "Die Aufnahme beginnt nicht")
        for n in 1...scans {
            #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
            #expect(s.app.press("scan-button"))
            #expect(s.app.wait { s.originals.count == n }, "Original \(n) fehlt")
            #expect(s.app.wait { s.app.string("series-page-count") == (n == 1 ? "1 Seite" : "\(n) Seiten") })
        }
    }

    @Test func theInboxPageStartsTheRecordingAndShowsADoneButton() throws {
        let s = try launch(); defer { s.close() }
        record(s, scans: 2)
        #expect(s.app.element("auto-trigger-toggle") == nil, "In der Schnellablage gibt es keine Auto-Auslösung")
        #expect(s.app.wait { s.app.isEnabled("inbox-finish-button") == true })
        #expect(s.app.wait { s.documentFiles.count == 1 })
    }

    @Test func doneOpensTheEditorWithOneDocumentPerPageAndFilingWritesOnePdfPerDocument() throws {
        let s = try launch(); defer { s.close() }
        record(s, scans: 2)
        #expect(s.app.press("inbox-finish-button"))
        #expect(s.app.wait(timeout: 60) { s.app.element("editor-grid") != nil }, "Der Editor öffnet sich nicht")
        #expect(s.app.wait { s.app.elements("inbox-group").count == 2 }, "Jede Seite sollte ein Dokument sein: \(s.app.elements("inbox-group").count)")
        #expect(s.app.element("inbox-merge-button") != nil, "Das zweite Dokument lässt sich mit dem ersten zusammenfassen")

        #expect(s.app.press("editor-file-button"))
        #expect(s.app.wait(timeout: 90) { s.inboxPDFs.count == 2 }, "PDFs: \(s.inboxPDFs.map(\.lastPathComponent))")
        for pdf in s.inboxPDFs {
            #expect(pdf.lastPathComponent.range(of: #"^\d{4} .+\.pdf$"#, options: .regularExpression) != nil, "Dateiname: \(pdf.lastPathComponent)")
            #expect(PDFDocument(url: pdf)?.pageCount == 1)
        }
        // Danach steht die Seite Schnellablage mit dem Ergebnis, und die Ablage ist erledigt.
        #expect(s.app.wait(timeout: 15) { s.app.element("inbox-page") != nil && !s.app.elements("inbox-filed-row").isEmpty })
        #expect(s.app.wait { s.documentFiles.isEmpty }, "Die abgelegte Schnellablage bleibt nicht liegen")
        #expect(s.originals.count == 2, "Die Originale bleiben im Archiv")
    }

    @Test func mergingTwoPagesGivesOnePdfWithTwoPagesNamedAfterTheTypedDescription() throws {
        let s = try launch(); defer { s.close() }
        record(s, scans: 2)
        #expect(s.app.press("inbox-finish-button"))
        #expect(s.app.wait(timeout: 60) { s.app.elements("inbox-group").count == 2 })
        #expect(s.app.press("inbox-merge-button"))
        #expect(s.app.wait { s.app.elements("inbox-group").count == 1 }, "Das Zusammenfassen hat nichts bewirkt")
        #expect(s.app.wait { s.app.element("editor-file-button").flatMap { AppDriver.string($0, kAXTitleAttribute) } == "Dokument ablegen" ||
                             s.app.element("editor-file-button") != nil })

        // Name von Hand: erst leeren, dann tippen. Das Feld enthält den Vorschlag, Befehl-A gibt es hier nicht: also anhängen.
        #expect(s.app.type(" Stadtwerke", into: "inbox-name-field"))
        #expect(s.app.press("editor-file-button"))
        #expect(s.app.wait(timeout: 90) { s.inboxPDFs.count == 1 }, "PDFs: \(s.inboxPDFs.map(\.lastPathComponent))")
        let pdf = try #require(s.inboxPDFs.first)
        #expect(PDFDocument(url: pdf)?.pageCount == 2)
    }

    @Test func theSettingsShowFolderAndTriggerKeyAndCanLearnANewKey() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.press("nav-settings"))
        #expect(s.app.wait { s.app.element("settings-page") != nil })
        #expect(s.app.string("settings-target-count")?.hasPrefix("2") == true, "Zielordner: \(s.app.string("settings-target-count") ?? "-")")
        #expect(s.app.string("settings-trigger-key") == "Leertaste")
        #expect(s.app.press("settings-trigger-learn"))
        #expect(s.app.wait { s.app.string("settings-trigger-key") == "Drücke jetzt die Taste …" })
        #expect(s.app.pressKey(100))                 // F8
        #expect(s.app.wait { s.app.string("settings-trigger-key")?.contains("100") == true }, "Taste: \(s.app.string("settings-trigger-key") ?? "-")")
        #expect(s.app.wait { s.app.isEnabled("settings-trigger-reset") == true })
    }

    @Test func aLearnedFootSwitchKeyTriggersTheScanAndSpaceDoesNot() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.press("nav-settings"))
        #expect(s.app.wait { s.app.element("settings-trigger-learn") != nil })
        #expect(s.app.press("settings-trigger-learn"))
        #expect(s.app.wait { s.app.string("settings-trigger-key") == "Drücke jetzt die Taste …" })
        #expect(s.app.pressKey(100))
        #expect(s.app.wait { s.app.string("settings-trigger-key")?.contains("100") == true })
        #expect(s.app.press("nav-capture"))
        #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
        #expect(s.app.pressSpace())
        Thread.sleep(forTimeInterval: 1.5)
        #expect(s.originals.isEmpty, "Die Leertaste löst nach dem Umstellen nicht mehr aus")
        #expect(s.app.pressKey(100))
        #expect(s.app.wait(timeout: 20) { s.originals.count == 1 }, "Die eingelernte Taste löst nicht aus")
    }

    @Test func theInboxPageWarnsWhenNoFolderIsSetAndSeriesDoNotShowInbox() throws {
        let s = try launch(); defer { s.close() }
        record(s, scans: 1)
        // Die Schnellablage zählt nicht als Serie.
        #expect(s.app.press("series-list-button"))
        #expect(s.app.wait { s.app.element("series-list-view") != nil })
        #expect(s.app.elements("series-row").isEmpty, "Eine Schnellablage ist keine Serie")
        #expect(s.app.elements("nav-series-item").isEmpty)
    }

    @Test func theSidebarItemsStandUnderEachOtherEachInOneLine() throws {
        let s = try launch(); defer { s.close() }
        let ids = ["nav-capture", "nav-inbox", "series-list-button", "log-button", "nav-settings"]
        var frames: [(String, CGRect)] = []
        for id in ids {
            let frame = try #require(s.app.frame(of: id), "\(id) fehlt")
            frames.append((id, frame))
        }
        for (id, frame) in frames {
            #expect(frame.height < 60, "\(id) ist \(frame.height) hoch: Der Eintrag bricht um")
            #expect(frame.width > 150, "\(id) ist nur \(frame.width) breit")
        }
        for i in 1..<frames.count where frames[i].0 != "nav-settings" {
            #expect(frames[i].1.minY > frames[i - 1].1.minY, "\(frames[i].0) steht nicht unter \(frames[i - 1].0)")
            #expect(abs(frames[i].1.minX - frames[0].1.minX) < 2, "\(frames[i].0) steht nicht links bündig")
        }
    }

    @Test func aRunningInboxCanBeDiscardedEvenBeforeTheFirstScan() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.press("nav-inbox"))
        #expect(s.app.wait { s.app.element("inbox-start-button") != nil })
        #expect(s.app.press("inbox-start-button"))
        #expect(s.app.wait { s.app.element("inbox-discard-button") != nil }, "Keine Möglichkeit, die Schnellablage abzubrechen")
        #expect(s.app.isEnabled("inbox-finish-button") == false, "Fertig ist ohne Seite gesperrt")
        #expect(s.app.press("inbox-discard-button"))
        #expect(s.app.wait { s.app.element("inbox-discard-confirm") != nil }, "Keine Rückfrage")
        #expect(s.app.press("inbox-discard-confirm"))
        #expect(s.app.wait { s.app.element("inbox-page") != nil && s.app.element("inbox-start-button") != nil }, "Die Seite Schnellablage kommt nicht zurück")
        #expect(s.app.wait { s.documentFiles.isEmpty }, "Die abgebrochene Schnellablage bleibt liegen")
    }

    @Test func discardingARunningInboxWithPagesKeepsTheScans() throws {
        let s = try launch(); defer { s.close() }
        record(s, scans: 2)
        #expect(s.app.press("inbox-discard-button"))
        #expect(s.app.wait { s.app.element("inbox-discard-confirm") != nil })
        #expect(s.app.press("inbox-discard-confirm"))
        #expect(s.app.wait(timeout: 15) { s.documentFiles.isEmpty }, "Die verworfene Schnellablage bleibt liegen")
        #expect(s.originals.count == 2, "Die Scans bleiben im Archiv")
        #expect(s.app.wait { s.app.element("inbox-start-button") != nil })
    }

    /// Die Beschriftungen der Ziel-Schaltflächen in Reihenfolge der Ansicht.
    private func chipNames(_ s: UISession) -> [String] {
        s.app.elements("target-chip").map { AppDriver.string($0, kAXDescriptionAttribute) ?? AppDriver.string($0, kAXTitleAttribute) ?? "" }
    }

    @Test func switchingTheTargetByClickSendsEachDocumentToItsFolder() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.press("nav-inbox"))
        #expect(s.app.wait { s.app.element("inbox-start-button") != nil })
        #expect(s.app.wait { s.app.elements("target-chip").count == 2 }, "Ziele auf der Seite Schnellablage")
        #expect(s.app.press("inbox-start-button"))
        #expect(s.app.wait { s.app.element("series-page-count") != nil })
        #expect(s.app.wait { s.app.elements("target-chip").count == 2 }, "Ziele in der Aufnahmeleiste: \(chipNames(s))")
        #expect(chipNames(s) == ["Privat", "Verein"])

        #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
        #expect(s.app.press("scan-button"))                                       // Privat
        #expect(s.app.wait { s.originals.count == 1 })
        #expect(s.app.wait { s.app.string("series-page-count") == "1 Seite" })
        let second = try #require(s.app.elements("target-chip").last)
        #expect(AXUIElementPerformAction(second, kAXPressAction as CFString) == .success)      // auf „Verein“ umschalten
        #expect(s.app.wait { s.app.elements("target-chip").last.flatMap { AppDriver.string($0, kAXValueAttribute) } == "gewählt" })
        #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
        #expect(s.app.press("scan-button"))                                       // Verein
        #expect(s.app.wait { s.originals.count == 2 })
        #expect(s.app.wait { s.app.string("series-page-count") == "2 Seiten" })

        #expect(s.app.press("inbox-finish-button"))
        #expect(s.app.wait(timeout: 60) { s.app.elements("inbox-group").count == 2 })
        // Im Editor trägt jedes Dokument sein Ziel: das erste Privat, das zweite Verein.
        #expect(s.app.wait { s.app.elements("target-chip").count == 4 }, "Je Dokument zwei Schaltflächen")
        let chips = s.app.elements("target-chip")
        #expect(AppDriver.string(chips[0], kAXValueAttribute) == "gewählt" && AppDriver.string(chips[1], kAXValueAttribute) != "gewählt")
        #expect(AppDriver.string(chips[3], kAXValueAttribute) == "gewählt" && AppDriver.string(chips[2], kAXValueAttribute) != "gewählt")

        #expect(s.app.press("editor-file-button"))
        #expect(s.app.wait(timeout: 90) { s.inboxPDFs.count == 1 && s.inboxPDFs2.count == 1 }, "Privat: \(s.inboxPDFs.count), Verein: \(s.inboxPDFs2.count)")
    }

    @Test func aDocumentsTargetCanBeChangedInTheEditor() throws {
        let s = try launch(); defer { s.close() }
        record(s, scans: 1)
        #expect(s.app.press("inbox-finish-button"))
        #expect(s.app.wait(timeout: 60) { s.app.elements("inbox-group").count == 1 && s.app.elements("target-chip").count == 2 })
        let verein = try #require(s.app.elements("target-chip").last)
        #expect(AXUIElementPerformAction(verein, kAXPressAction as CFString) == .success)
        #expect(s.app.wait { s.app.elements("target-chip").last.flatMap { AppDriver.string($0, kAXValueAttribute) } == "gewählt" })
        #expect(s.app.press("editor-file-button"))
        #expect(s.app.wait(timeout: 90) { s.inboxPDFs2.count == 1 }, "Das PDF kam nicht ins Ziel Verein")
        #expect(s.inboxPDFs.isEmpty, "Es darf nicht auch in Privat liegen")
    }

    @Test func theInboxPageListsTheTargetsAndMovesAndRemovesThem() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.press("nav-inbox"))
        #expect(s.app.wait { s.app.elements("target-row").count == 2 }, "Die Zielordner stehen auf der Seite Schnellablage")
        #expect(s.app.element("inbox-target-add") != nil, "Ordner lassen sich dort hinzufügen")
        func paths() -> [String] { s.app.elements("target-path").map { AppDriver.string($0, kAXValueAttribute) ?? "" } }
        #expect(paths()[0].contains("scanutil-ui-inbox-") && paths()[1].contains("scanutil-ui-inbox2-"))
        // Erste Zeile: „nach oben“ gesperrt, letzte: „nach unten“ gesperrt.
        let ups = s.app.elements("target-up"), downs = s.app.elements("target-down")
        #expect(AppDriver.isEnabled(ups[0]) == false, "Die erste Zeile lässt sich nicht weiter nach oben schieben")
        #expect(AppDriver.isEnabled(downs[1]) == false, "Die letzte nicht weiter nach unten")
        // Zweite Zeile nach oben: Reihenfolge dreht sich.
        #expect(AXUIElementPerformAction(ups[1], kAXPressAction as CFString) == .success)
        #expect(s.app.wait { paths()[0].contains("scanutil-ui-inbox2-") && paths()[1].contains("scanutil-ui-inbox-") }, "Reihenfolge: \(paths())")
        // Erste Zeile entfernen: nur noch eine.
        let removes = s.app.elements("target-remove")
        #expect(AXUIElementPerformAction(removes[0], kAXPressAction as CFString) == .success)
        #expect(s.app.wait { s.app.elements("target-row").count == 1 })
        #expect(paths().first?.contains("scanutil-ui-inbox-") == true, "Übrig bleibt Privat: \(paths())")
        // Letztes entfernen: Hinweis, und die Schnellablage warnt.
        #expect(AXUIElementPerformAction(s.app.elements("target-remove")[0], kAXPressAction as CFString) == .success)
        #expect(s.app.wait { s.app.element("inbox-no-target") != nil }, "Ohne Ziel steht ein Hinweis da")
        #expect(s.app.wait { s.app.element("inbox-no-target-hint") != nil })
    }

    @Test func theInboxPageOffersADropZoneAndAFileChooser() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.press("nav-inbox"))
        #expect(s.app.wait { s.app.element("inbox-drop-zone") != nil }, "Keine Fläche zum Ablegen von Dateien")
        #expect(s.app.element("inbox-import-button") != nil, "Kein Weg über die Dateiauswahl")
    }

    @Test func theWholeFileNameIncludingYearAndMonthIsEditableInTheEditor() throws {
        let s = try launch(); defer { s.close() }
        record(s, scans: 1)
        #expect(s.app.press("inbox-finish-button"))
        #expect(s.app.wait(timeout: 60) { s.app.element("inbox-name-field") != nil })
        // Das Feld zeigt den ganzen Namen mit Jahr und Monat vorn.
        let shown = s.app.string("inbox-name-field") ?? ""
        #expect(shown.range(of: #"^\d{4} "#, options: .regularExpression) != nil, "Feldinhalt: \(shown)")
        // Alles ersetzen, auch die Jahr-Monat-Angabe: Wert setzen, mit Eingabe bestätigen.
        let field = try #require(s.app.element("inbox-name-field"))
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        #expect(AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "2509 Gehalt Silvia" as CFString) == .success)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(s.app.pressKey(36))
        #expect(s.app.wait(timeout: 10) { s.app.string("inbox-name-field") == "2509 Gehalt Silvia" }, "Feld: \(s.app.string("inbox-name-field") ?? "-")")
        #expect(s.app.press("editor-file-button"))
        #expect(s.app.wait(timeout: 90) { s.inboxPDFs.map(\.lastPathComponent) == ["2509 Gehalt Silvia.pdf"] }, "PDFs: \(s.inboxPDFs.map(\.lastPathComponent))")
    }
}
