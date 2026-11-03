import AppKit
import ApplicationServices
import Foundation
import Testing

/// Die Oberflächentests dürfen den Rechner des Entwicklers nicht blockieren: Sie nehmen weder den Fokus noch bewegen sie die Maus.
/// Dieser Test hält fest, welche App vorn liegt, und prüft nach jedem Schritt, dass es dieselbe ist.
/// Die Mausposition lässt sich dabei nicht vergleichen: Wer am Rechner sitzt, bewegt sie selbst. Dass die Tests den Zeiger nie
/// bewegen, ist deshalb eine Regel für den Treiber (kein `CGWarpMouseCursorPosition`, kein Ereignis über den HID-Pfad), keine Prüfung.
/// Läuft nur mit `SCANUTIL_UI_TESTS=1`.
@Suite("Oberfläche: Hintergrund", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SCANUTIL_UI_TESTS"] != nil))
struct HintergrundTests {
    private struct Snapshot: Equatable {
        let frontmost: pid_t?
        static func now() -> Snapshot { Snapshot(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier) }
    }

    private func unchanged(_ before: Snapshot, after step: String, app: AppDriver) {
        let now = Snapshot.now()
        #expect(now.frontmost == before.frontmost, "Nach „\(step)“ liegt eine andere App vorn (vorher \(String(describing: before.frontmost)), jetzt \(String(describing: now.frontmost)), die getestete App hat \(app.pid))")
        #expect(!app.isFrontmost, "Nach „\(step)“ ist die getestete App vorn")
    }

    @Test func theAppRunsAndIsOperatedWithoutTakingFocusOrMovingTheMouse() throws {
        let before = Snapshot.now()
        let s = try UISession.launch(mode: "document"); defer { s.close() }
        #expect(s.app.wait { s.app.string("status-text") == "Bereit: Mock-Scanner" })
        unchanged(before, after: "Start", app: s.app)

        // Serie, Scannen, Leertaste, Zoomknopf, Protokoll, Export. Die Serie zuerst: Nach einem Scan ist „Serie beginnen“ gesperrt,
        // bis die App wieder bereit ist.
        #expect(s.app.press("series-start-button"))
        #expect(s.app.wait { s.app.element("series-page-count") != nil }, "Die Serie begann nicht")
        unchanged(before, after: "Serie beginnen", app: s.app)

        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == 1 })
        unchanged(before, after: "Scannen per Knopf", app: s.app)

        #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
        #expect(s.app.pressSpace())
        #expect(s.app.wait(timeout: 20) { s.originals.count == 2 }, "Die Leertaste erreichte die App im Hintergrund nicht")
        unchanged(before, after: "Leertaste", app: s.app)
        #expect(s.app.wait { s.app.string("series-page-count") == "2 Seiten" })

        #expect(s.app.wait { s.app.isEnabled("series-export-button") == true }, "Der Export bleibt gesperrt")
        #expect(s.app.wait(timeout: 20) { s.app.element("scan-zoom-in") != nil })
        #expect(s.app.press("scan-zoom-in"))
        unchanged(before, after: "Zoomknopf", app: s.app)

        #expect(s.app.press("log-button"))
        #expect(s.app.wait { s.app.element("log-view") != nil }, "Das Protokoll öffnet sich im Hintergrund nicht")
        unchanged(before, after: "Protokoll öffnen", app: s.app)

        // Der Speicherdialog ist modal und öffnet sich gern im Vordergrund.
        s.app.pressOpeningDialog("series-export-button")
        #expect(s.app.wait(timeout: 10) { s.app.hasDialog }, "Der Speicherdialog öffnet sich nicht")
        unchanged(before, after: "Speicherdialog offen", app: s.app)
        #expect(s.app.confirmDialog())
        #expect(s.app.wait(timeout: 60) { !s.pdfs.isEmpty })
        unchanged(before, after: "Export", app: s.app)
    }

    @Test func theMouseWheelReachesTheAppWithoutTheRealPointer() throws {
        let before = Snapshot.now()
        let s = try UISession.launch(mode: "document"); defer { s.close() }
        #expect(s.app.wait { s.app.integerInText("preview-zoom-level") != nil })
        let fitted = try #require(s.app.integerInText("preview-zoom-level"))
        let bar = try #require(s.app.frame(of: "preview-zoom-in"))
        s.app.scrollWheel(at: CGPoint(x: bar.minX - 300, y: bar.minY - 150), lines: 3)
        #expect(s.app.wait { (s.app.integerInText("preview-zoom-level") ?? 0) > fitted },
                "Das Mausrad erreichte die App nicht (Fenster \(String(describing: s.app.mainWindowNumber)))")
        unchanged(before, after: "Mausrad", app: s.app)
    }
}
