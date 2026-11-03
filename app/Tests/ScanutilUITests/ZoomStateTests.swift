import CoreGraphics
import Foundation
import Testing
@testable import ScanutilUI

@Suite("Zoom")
struct ZoomStateTests {
    private let view = CGSize(width: 800, height: 600)
    /// Ein Bild im Format 4:3, in die Ansicht eingepasst: 800 × 600.
    private let fit = CGSize(width: 800, height: 600)
    private let max = 8.0

    private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1e-6) -> Bool { abs(a - b) <= tolerance }

    @Test func fitSizeKeepsTheAspectRatioInsideTheView() {
        #expect(ZoomState.fitSize(image: CGSize(width: 400, height: 300), in: view) == CGSize(width: 800, height: 600))
        #expect(ZoomState.fitSize(image: CGSize(width: 300, height: 600), in: view) == CGSize(width: 300, height: 600))   // hochkant: Höhe bestimmt
        #expect(ZoomState.fitSize(image: CGSize(width: 1000, height: 100), in: view) == CGSize(width: 800, height: 80))   // sehr breit
        #expect(ZoomState.fitSize(image: .zero, in: view) == .zero)
        #expect(ZoomState.fitSize(image: CGSize(width: 10, height: 10), in: .zero) == .zero)
    }

    @Test func startsAtFitAndCannotZoomOutBelowIt() {
        var state = ZoomState()
        #expect(state.scale == 1 && state.offset == .zero && !state.isZoomed)
        state.zoom(by: 0.5, fit: fit, view: view, maxScale: max)
        #expect(state.scale == 1)
    }

    @Test func zoomIsCappedAtTheMaximum() {
        var state = ZoomState()
        state.zoom(by: 100, fit: fit, view: view, maxScale: max)
        #expect(state.scale == max)
    }

    @Test func zoomingAroundTheCenterKeepsTheImageCentered() {
        var state = ZoomState()
        state.zoom(by: 2, fit: fit, view: view, maxScale: max)
        #expect(state.scale == 2 && state.offset == .zero)
    }

    @Test func theImagePointUnderTheAnchorStaysWhereItIs() {
        var state = ZoomState()
        let anchor = CGPoint(x: 200, y: -100)   // rechts von der Mitte und oberhalb
        // Bildpunkt unter dem Anker vor dem Zoom (in Bildkoordinaten ab Bildmitte, bei Zoom 1).
        let before = CGPoint(x: (anchor.x - state.offset.width) / state.scale, y: (anchor.y - state.offset.height) / state.scale)
        state.zoom(by: 3, around: anchor, fit: fit, view: view, maxScale: max)
        let after = CGPoint(x: (anchor.x - state.offset.width) / state.scale, y: (anchor.y - state.offset.height) / state.scale)
        #expect(near(before.x, after.x) && near(before.y, after.y), "Punkt wanderte von \\(before) nach \\(after)")
    }

    @Test func anchorStaysFixedAcrossSeveralZoomSteps() {
        var state = ZoomState()
        let anchor = CGPoint(x: -150, y: 120)
        let start = CGPoint(x: anchor.x, y: anchor.y)
        for _ in 0..<4 { state.zoom(by: ZoomState.buttonStep, around: anchor, fit: fit, view: view, maxScale: max) }
        let p = CGPoint(x: (anchor.x - state.offset.width) / state.scale, y: (anchor.y - state.offset.height) / state.scale)
        #expect(near(p.x, start.x) && near(p.y, start.y), "Punkt: \\(p), erwartet \\(start)")
    }

    @Test func panIsLimitedToTheOverhang() {
        var state = ZoomState()
        state.zoom(by: 2, fit: fit, view: view, maxScale: max)          // Bild 1600 × 1200 in 800 × 600
        state.pan(by: CGSize(width: 10_000, height: -10_000), fit: fit, view: view)
        #expect(state.offset == CGSize(width: 400, height: -300))        // Überstand je Seite: (1600 − 800) / 2
        state.pan(by: CGSize(width: -10_000, height: 10_000), fit: fit, view: view)
        #expect(state.offset == CGSize(width: -400, height: 300))
    }

    @Test func aSmallImageCannotBePannedAtAll() {
        var state = ZoomState()
        state.pan(by: CGSize(width: 50, height: 50), fit: fit, view: view)
        #expect(state.offset == .zero)
        // Auch bei Zoom 1,2 in einer Richtung, in der das Bild noch in die Ansicht passt (sehr breites Bild).
        let wide = CGSize(width: 800, height: 80)
        var s = ZoomState()
        s.zoom(by: 2, fit: wide, view: view, maxScale: max)
        s.pan(by: CGSize(width: 0, height: 500), fit: wide, view: view)
        #expect(s.offset.height == 0, "Das Bild (160 hoch) passt senkrecht in die Ansicht")
    }

    @Test func zoomingOutAgainReturnsTheImageToTheCenter() {
        var state = ZoomState()
        let anchor = CGPoint(x: 300, y: 200)
        state.zoom(by: 4, around: anchor, fit: fit, view: view, maxScale: max)
        #expect(state.offset != .zero)
        state.zoom(by: 0.25, around: anchor, fit: fit, view: view, maxScale: max)
        #expect(state.scale == 1)
        #expect(state.offset == .zero, "Bei Zoom 1 darf nichts verschoben sein: \\(state.offset)")
    }

    @Test func zoomingTowardTheCornerNeverShowsEmptySpace() {
        var state = ZoomState()
        state.zoom(by: 2, around: CGPoint(x: 400, y: 300), fit: fit, view: view, maxScale: max)   // äußerste Ecke
        #expect(state.offset == CGSize(width: -400, height: -300))   // Ecke bleibt an der Ecke, kein leerer Rand
    }

    @Test func resetGoesBackToFit() {
        var state = ZoomState()
        state.zoom(by: 3, around: CGPoint(x: 100, y: 50), fit: fit, view: view, maxScale: max)
        state.reset()
        #expect(state == ZoomState())
    }

    @Test func setOffsetIsClamped() {
        var state = ZoomState()
        state.zoom(by: 2, fit: fit, view: view, maxScale: max)
        state.setOffset(CGSize(width: 99_999, height: 0), fit: fit, view: view)
        #expect(state.offset.width == 400)
    }

    @Test func actualSizeMapsOneImagePixelToOneScreenPixel() {
        // 5696 Pixel breites Original, eingepasst 900 Punkte breit, Retina (2 Pixel je Punkt).
        let scale = ZoomState.actualScale(referencePixelWidth: 5696, fitWidth: 900, backingScale: 2)
        #expect(near(scale, 5696.0 / 1800.0, 1e-9))
        let percent = ZoomState.percent(scale: scale, referencePixelWidth: 5696, fitWidth: 900, backingScale: 2)
        #expect(near(percent, 100, 1e-9))
        // Eingepasst zeigt dasselbe Bild nur einen Teil der Auflösung.
        let fitPercent = ZoomState.percent(scale: 1, referencePixelWidth: 5696, fitWidth: 900, backingScale: 2)
        #expect(near(fitPercent, 1800.0 / 5696.0 * 100, 1e-9))
    }

    @Test func degenerateInputsDoNotProduceNonsense() {
        #expect(ZoomState.actualScale(referencePixelWidth: 0, fitWidth: 900, backingScale: 2) == 1)
        #expect(ZoomState.actualScale(referencePixelWidth: 100, fitWidth: 0, backingScale: 2) == 1)
        #expect(ZoomState.percent(scale: 2, referencePixelWidth: 0, fitWidth: 900, backingScale: 2) == 0)
        var state = ZoomState()
        state.zoom(by: .nan, fit: fit, view: view, maxScale: max)
        #expect(state.scale == 1 && state.offset == .zero)
        state.zoom(by: 2, fit: .zero, view: .zero, maxScale: max)
        #expect(state.scale == 2 && state.offset == .zero)
    }

    @Test func theMaximumLeavesRoomBeyondActualSize() {
        #expect(ZoomState.maxScale(actualScale: 1) == 8)
        #expect(ZoomState.maxScale(actualScale: 5) == 15)
    }
}
