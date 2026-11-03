import ApplicationServices
import Foundation
import Testing

/// Zoom in der Live-Vorschau und in der Scanansicht, an der echten App. Läuft nur mit `SCANUTIL_UI_TESTS=1`.
@Suite("Oberfläche: Zoom", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SCANUTIL_UI_TESTS"] != nil))
struct ZoomOberflaechenTests {
    private func launch(mode: String = "document") throws -> UISession {
        let s = try UISession.launch(mode: mode)
        #expect(s.app.wait { s.app.string("status-text")?.hasPrefix("Bereit") == true }, "App wurde nicht bereit")
        return s
    }

    private func level(_ s: UISession, _ prefix: String) -> Int? { s.app.integerInText("\(prefix)-zoom-level") }

    /// Scannt einmal und wartet, bis die Scanansicht mit Zoom da ist und die Anzeige zur Ruhe kam. Die automatische Analyse
    /// tauscht die unkorrigierte gegen die zugeschnittene Ansicht aus: ein anderes Bild mit anderem Einpass-Zoom.
    private func scanOnce(_ s: UISession) {
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == 1 })
        #expect(s.app.wait(timeout: 20) { s.app.element("scan-zoom-level") != nil }, "Die Scanansicht hat keinen Zoom")
        #expect(s.app.wait(timeout: 30) { s.correctionFiles.count == 1 }, "Die Analyse wurde nicht fertig")
        #expect(settled(s, "scan"), "Die Anzeige kam nicht zur Ruhe: \(level(s, "scan") ?? -1) %")
    }

    /// Wartet, bis sich die Zoomanzeige 1,2 Sekunden lang nicht mehr ändert.
    private func settled(_ s: UISession, _ prefix: String, timeout: Double = 15) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        var last = level(s, prefix), since = Date()
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.2)
            let now = level(s, prefix)
            if now != last { last = now; since = Date() }
            if Date().timeIntervalSince(since) >= 1.2 { return last != nil }
        }
        return false
    }

    // MARK: Vorschau

    @Test func previewZoomButtonsChangeTheLevelAndFitGoesBack() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.wait { level(s, "preview") != nil }, "Die Vorschau hat keinen Zoom")
        let fitted = try #require(level(s, "preview"))
        // Eingepasst: Verkleinern und Einpassen sind gesperrt, es gibt nichts zu tun.
        #expect(s.app.isEnabled("preview-zoom-out") == false)
        #expect(s.app.isEnabled("preview-zoom-fit") == false)
        #expect(s.app.isEnabled("preview-zoom-in") == true)

        #expect(s.app.press("preview-zoom-in"))
        #expect(s.app.wait { (level(s, "preview") ?? 0) > fitted }, "Zoom \(level(s, "preview") ?? -1) % nach Vergrößern, vorher \(fitted) %")
        let once = try #require(level(s, "preview"))
        // Ein Schritt ist 1,5-fach; die Anzeige ist gerundet, bei kleinen Zahlen wiegt das schwer.
        let expected = Double(fitted) * ZoomState.buttonStepForTests
        #expect(abs(Double(once) - expected) <= 1.0, "Ein Schritt ist 1,5-fach: \(fitted) % → \(once) %, erwartet \(expected) %")
        #expect(s.app.isEnabled("preview-zoom-out") == true)
        #expect(s.app.isEnabled("preview-zoom-fit") == true)

        #expect(s.app.press("preview-zoom-in"))
        #expect(s.app.wait { (level(s, "preview") ?? 0) > once })

        #expect(s.app.press("preview-zoom-out"))
        #expect(s.app.wait { level(s, "preview") == once }, "Ein Schritt zurück: \(level(s, "preview") ?? -1) statt \(once)")

        #expect(s.app.press("preview-zoom-fit"))
        #expect(s.app.wait { level(s, "preview") == fitted }, "Einpassen: \(level(s, "preview") ?? -1) statt \(fitted)")
        #expect(s.app.isEnabled("preview-zoom-fit") == false)
    }

    @Test func actualSizeShowsOneHundredPercentOrIsDisabledWhenFittedIsAlreadyLarger() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.wait { level(s, "preview") != nil })
        let fitted = try #require(level(s, "preview"))
        if fitted >= 100 {
            // Das Fenster ist so groß, dass das eingepasste Bild schon über 1:1 liegt: kleiner als Einpassen zoomt man nicht.
            #expect(s.app.isEnabled("preview-zoom-actual") == false, "1:1 ist bei \(fitted) % eingepasst anklickbar, ohne etwas zu tun")
        } else {
            #expect(s.app.isEnabled("preview-zoom-actual") == true)
            #expect(s.app.press("preview-zoom-actual"))
            #expect(s.app.wait { level(s, "preview") == 100 }, "1:1 zeigt \(level(s, "preview") ?? -1) %")
        }
    }

    @Test func mouseWheelZoomsThePreviewAroundThePointer() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.wait { level(s, "preview") != nil })
        let fitted = try #require(level(s, "preview"))
        // Ein Punkt im linken Teil der Vorschau, links der Zoomleiste.
        let bar = try #require(s.app.frame(of: "preview-zoom-in"))
        let point = CGPoint(x: bar.minX - 300, y: bar.minY - 150)

        s.app.scrollWheel(at: point, lines: 3)
        let zoomed = s.app.wait { (level(s, "preview") ?? 0) > fitted }
        #expect(zoomed, "Mausrad nach oben hat nicht vergrößert: \(level(s, "preview") ?? -1) % statt über \(fitted) %")

        let after = level(s, "preview") ?? 0
        s.app.scrollWheel(at: point, lines: -3)
        #expect(s.app.wait { (level(s, "preview") ?? Int.max) < after }, "Mausrad nach unten hat nicht verkleinert")
    }

    // MARK: Scanansicht

    @Test func scanViewZoomsAndLoadsTheFullResolution() throws {
        let s = try launch(); defer { s.close() }
        scanOnce(s)
        let fitted = try #require(level(s, "scan"))
        #expect(s.app.element("scan-zoom-detail") == nil, "Volle Auflösung schon geladen, ohne gezoomt zu haben")

        // Dreimal vergrößern (3,4-fach) liegt über der Schwelle, ab der das Original in voller Auflösung nachgeladen wird.
        for _ in 0..<3 { #expect(s.app.press("scan-zoom-in")) }
        #expect(s.app.wait { (level(s, "scan") ?? 0) > fitted * 3 }, "Zoom \(level(s, "scan") ?? -1) % nach dreimal Vergrößern, eingepasst \(fitted) %")
        let zoomed = try #require(level(s, "scan"))
        #expect(s.app.wait(timeout: 30) { s.app.element("scan-zoom-detail") != nil }, "Die volle Auflösung wurde nicht nachgeladen")
        // Die Anzeige springt dabei nicht: derselbe Zoom vor und nach dem Laden.
        #expect(level(s, "scan") == zoomed, "Nach dem Nachladen zeigt die Anzeige \(level(s, "scan") ?? -1) % statt \(zoomed) %")

        #expect(s.app.press("scan-zoom-fit"))
        #expect(s.app.wait { level(s, "scan") == fitted })
    }

    @Test func aNewScanStartsFittedAgain() throws {
        let s = try launch(); defer { s.close() }
        scanOnce(s)
        let fitted = try #require(level(s, "scan"))
        #expect(s.app.press("scan-zoom-in"))
        #expect(s.app.press("scan-zoom-in"))
        #expect(s.app.wait { (level(s, "scan") ?? 0) > fitted })

        #expect(s.app.wait { s.app.isEnabled("scan-button") == true })
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == 2 })
        #expect(s.app.wait(timeout: 20) { level(s, "scan") == fitted }, "Der neue Scan zeigt \(level(s, "scan") ?? -1) % statt \(fitted) %")
    }

    @Test func bookPagesZoomIndependently() throws {
        let s = try launch(); defer { s.close() }
        #expect(s.app.press("book-mode-toggle"))
        #expect(s.app.press("series-start-button"))
        #expect(s.app.wait { s.app.element("series-page-count") != nil })
        #expect(s.app.press("scan-button"))
        #expect(s.app.wait { s.originals.count == 1 })
        #expect(s.app.wait(timeout: 30) { s.app.element("book-left-zoom-level") != nil && s.app.element("book-right-zoom-level") != nil },
                "Die Buchseiten haben keinen Zoom")
        let leftFit = try #require(level(s, "book-left"))
        let rightFit = try #require(level(s, "book-right"))
        #expect(s.app.press("book-left-zoom-in"))
        #expect(s.app.wait { (level(s, "book-left") ?? 0) > leftFit })
        #expect(level(s, "book-right") == rightFit, "Die rechte Seite hat mitgezoomt")
    }
}
