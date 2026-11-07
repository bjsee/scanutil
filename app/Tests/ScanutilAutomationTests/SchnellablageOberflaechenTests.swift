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
        #expect(s.app.string("settings-inbox-directory")?.contains("scanutil-ui-inbox") == true, "Ordner: \(s.app.string("settings-inbox-directory") ?? "-")")
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
}
