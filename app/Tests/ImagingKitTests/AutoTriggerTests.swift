import Testing
import CoreGraphics
@testable import ImagingKit

@Suite("AutoTrigger")
struct AutoTriggerTests {
    /// Gleichmäßig helles Bild, optional mit dunklen Zellen als „Text“ in einem Streifen.
    private func frame(brightness: UInt8 = 230, textRow: Int? = nil) -> FrameSignature {
        var cells = [UInt8](repeating: brightness, count: FrameSignature.width * FrameSignature.height)
        if let row = textRow {
            for x in 4..<40 { cells[row * FrameSignature.width + x] = 40 }
        }
        return FrameSignature(cells: cells)!
    }

    private let hand = { () -> FrameSignature in
        var cells = [UInt8](repeating: 230, count: FrameSignature.width * FrameSignature.height)
        for i in 0..<(cells.count / 3) { cells[i] = 60 }
        return FrameSignature(cells: cells)!
    }()

    /// Speist `frame` mit 10 Bildern pro Sekunde für `seconds` und gibt alle Ereignisse zurück.
    private func run(_ trigger: inout AutoTrigger, _ frame: FrameSignature, from start: Double, seconds: Double) -> [AutoTrigger.Event] {
        var events: [AutoTrigger.Event] = []
        var t = start
        while t < start + seconds - 1e-9 { events.append(trigger.feed(frame, at: t)); t += 0.1 }
        return events
    }

    @Test func signatureDifferences() {
        #expect(frame().meanDifference(to: frame()) == 0)
        #expect(frame().changedFraction(to: frame()) == 0)
        #expect(frame().meanDifference(to: hand) > 0.02)
        #expect(frame(textRow: 5).changedFraction(to: frame(textRow: 20)) > 0.01)
        #expect(FrameSignature(cells: [1, 2, 3]) == nil)
    }

    @Test func signatureFromImage() {
        let space = CGColorSpaceCreateDeviceGray()
        let context = CGContext(data: nil, width: 480, height: 360, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: 0)!
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
        let signature = FrameSignature(image: context.makeImage()!)!
        #expect(signature.cells.allSatisfy { $0 >= 250 })
    }

    @Test func firesOnceAfterCalmWhenStartingOnAPage() {
        var trigger = AutoTrigger()
        let events = run(&trigger, frame(textRow: 5), from: 0, seconds: 3)
        #expect(events.filter { $0 == .fire }.count == 1)
        // Und sonst nichts: auch keine Dauerfeuer-Meldungen über Dubletten, solange die Seite ruhig liegt.
        #expect(events.filter { $0 != .none }.count == 1)
        // Danach bleibt es still, obwohl die Seite weiter ruhig liegt.
        #expect(trigger.phase == .waitingForMotion)
    }

    @Test func doesNotFireBeforeCalmDuration() {
        var trigger = AutoTrigger()
        let events = run(&trigger, frame(textRow: 5), from: 0, seconds: 0.5)
        #expect(!events.contains(.fire))
    }

    @Test func pageTurnFiresAgain() {
        var trigger = AutoTrigger()
        var fires = 0
        func go(_ f: FrameSignature, _ from: Double, _ s: Double) { fires += run(&trigger, f, from: from, seconds: s).filter { $0 == .fire }.count }
        go(frame(textRow: 5), 0, 2)      // Seite 1
        go(hand, 2, 0.6)                 // Hand blättert
        go(frame(textRow: 20), 2.6, 2)   // Seite 2
        go(hand, 4.6, 0.6)
        go(frame(textRow: 12), 5.2, 2)   // Seite 3
        #expect(fires == 3)
    }

    @Test func handPassingWithoutPageChangeIsSkipped() {
        var trigger = AutoTrigger()
        _ = run(&trigger, frame(textRow: 5), from: 0, seconds: 2)       // Seite 1 aufgenommen
        _ = run(&trigger, hand, from: 2, seconds: 0.6)                  // Hand im Bild
        let events = run(&trigger, frame(textRow: 5), from: 2.6, seconds: 2)  // dieselbe Seite
        #expect(!events.contains(.fire))
        #expect(events.filter { $0 == .skippedDuplicate }.count == 1)   // einmal gemeldet, nicht in jedem Bild
    }

    @Test func slowDriftIsNotCalm() {
        var trigger = AutoTrigger()
        var fired = false
        // Jedes Bild ändert sich nur wenig zum vorigen, insgesamt aber deutlich: die Seite wird langsam geschoben.
        for i in 0..<40 {
            let f = frame(brightness: UInt8(230 - i * 3))
            if trigger.feed(f, at: Double(i) * 0.1) == .fire { fired = true }
        }
        #expect(!fired)
    }

    @Test func noFireOnStartWaitsForMotion() {
        var config = AutoTrigger.Configuration(); config.fireOnStart = false
        var trigger = AutoTrigger(configuration: config)
        #expect(!run(&trigger, frame(textRow: 5), from: 0, seconds: 3).contains(.fire))
        _ = run(&trigger, hand, from: 3, seconds: 0.5)
        #expect(run(&trigger, frame(textRow: 9), from: 3.5, seconds: 2).contains(.fire))
    }

    @Test func manualCaptureBlocksDuplicateAutoShot() {
        var trigger = AutoTrigger()
        let page = frame(textRow: 5)
        _ = trigger.feed(page, at: 0)
        trigger.noteManualCapture(of: page)
        #expect(!run(&trigger, page, from: 0.1, seconds: 3).contains(.fire))
        _ = run(&trigger, hand, from: 3.1, seconds: 0.5)
        #expect(!run(&trigger, page, from: 3.6, seconds: 2).contains(.fire))   // gleiche Seite: nur Dublette
        _ = run(&trigger, hand, from: 5.6, seconds: 0.5)
        #expect(run(&trigger, frame(textRow: 18), from: 6.1, seconds: 2).contains(.fire))
    }

    @Test func resetStartsOver() {
        var trigger = AutoTrigger()
        #expect(run(&trigger, frame(textRow: 5), from: 0, seconds: 2).contains(.fire))
        trigger.reset()
        #expect(run(&trigger, frame(textRow: 5), from: 10, seconds: 2).contains(.fire))
    }

    @Test func calmPhaseReportsProgress() {
        var trigger = AutoTrigger()
        _ = run(&trigger, frame(textRow: 5), from: 0, seconds: 0.5)
        if case .calm(let seconds) = trigger.phase { #expect(seconds > 0.2 && seconds < 0.8) }
        else { Issue.record("Phase war \(trigger.phase)") }
    }
}
