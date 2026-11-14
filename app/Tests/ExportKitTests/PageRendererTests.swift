import Testing
import CoreGraphics
import Foundation
import ArchiveKit
import ImagingKit
@testable import ExportKit

@Suite("Seiten aus zwei Scans rechnen")
struct PageRendererTests {
    private func solid(_ w: Int, _ h: Int, _ gray: UInt8) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { pixels[i * 4] = gray; pixels[i * 4 + 1] = gray; pixels[i * 4 + 2] = gray; pixels[i * 4 + 3] = 255 }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(pixels) as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func quad(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Quad {
        Quad(topLeft: .init(x: x0, y: y0), topRight: .init(x: x1, y: y0), bottomRight: .init(x: x1, y: y1), bottomLeft: .init(x: x0, y: y1))
    }

    @Test func scaleIsOneWithoutCropAndWhenTheCropIsOnlyCutNotStretched() {
        let source = solid(200, 100, 100)
        var c = Corrections(); c.enabled = true
        #expect(abs(PageRenderer.scale(of: source, source: source, corrections: c) - 1) < 1e-9)
        c.crop = CropCorrection(quad: quad(0, 0, 0.5, 1), enabled: true, source: .manual)
        let half = solid(100, 100, 100)
        #expect(abs(PageRenderer.scale(of: half, source: source, corrections: c) - 1) < 1e-9, "Halbes Bild ohne Strecken: Maßstab 1")
        #expect(abs(PageRenderer.scale(of: solid(200, 200, 100), source: source, corrections: c) - 2) < 1e-9, "Auf das Doppelte gestreckt: Maßstab 2")
    }

    @Test func aTurnSwapsWidthAndHeightInTheExpectedSize() {
        let source = solid(200, 100, 100)
        var c = Corrections(); c.enabled = true; c.quarterTurns = 1
        #expect(abs(PageRenderer.scale(of: solid(100, 200, 100), source: source, corrections: c) - 1) < 1e-9)
    }

    @Test func aPartInAnotherScaleIsBroughtToTheScaleOfTheOther() {
        let image = solid(200, 100, 100)
        let smaller = PageRenderer.matchScale(image, of: 2, to: 1)
        #expect(smaller.width == 100 && smaller.height == 50, "Doppelt so groß gerechnet: halbieren")
        let bigger = PageRenderer.matchScale(image, of: 1, to: 1.5)
        #expect(bigger.width == 300 && bigger.height == 150)
        let same = PageRenderer.matchScale(image, of: 1, to: 1.03)
        #expect(same === image, "Unter 5 % bleibt das Bild, wie es ist")
    }

    @Test func aSinglePageIsRenderedFromItsScanAndAMissingScanGivesNothing() {
        let page = DocumentPage(scanID: UUID())
        #expect(PageRenderer.render(page) { _ in nil } == nil)
        let image = solid(60, 40, 90)
        #expect(PageRenderer.render(page) { _ in image }?.width == 60)
        let joined = DocumentPage(scanID: UUID(), joined: JoinedPart(scanID: UUID()))
        let first = page.scanID
        #expect(PageRenderer.render(DocumentPage(scanID: first, joined: JoinedPart(scanID: UUID()))) { $0 == first ? image : nil } == nil,
                "Fehlt der zweite Scan, lässt sich die Seite nicht rechnen")
        _ = joined
    }
}
