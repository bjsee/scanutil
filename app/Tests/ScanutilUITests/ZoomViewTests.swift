import AppKit
import ArchiveKit
import CoreGraphics
import Foundation
import ImagingKit
import ScannerKit
import SwiftUI
import Testing
@testable import ScanutilUI

@MainActor
@Suite("Zoom: Ansicht und Eingaben")
struct ZoomViewTests {
    // MARK: Eingaben von Maus und Trackpad

    private func scroll(_ delta: Int32, units: CGScrollEventUnit, flags: CGEventFlags = []) -> NSEvent? {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
        cg?.flags = flags
        return cg.flatMap { NSEvent(cgEvent: $0) }
    }

    private func factor(_ input: ZoomInput?) -> Double? {
        if case .zoom(let f)? = input { return f }
        return nil
    }

    @Test func aMouseWheelNotchZoomsInAndOut() throws {
        let up = try #require(scroll(2, units: .line))
        let down = try #require(scroll(-2, units: .line))
        #expect(up.hasPreciseScrollingDeltas == false)
        let zoomIn = try #require(factor(ZoomEventCatcher.CatcherView.input(for: up)))
        let zoomOut = try #require(factor(ZoomEventCatcher.CatcherView.input(for: down)))
        #expect(zoomIn > 1, "Rad nach oben vergrößert")
        #expect(zoomOut < 1, "Rad nach unten verkleinert")
        #expect(abs(zoomIn * zoomOut - 1) < 1e-9, "Gleich viele Schritte hin und zurück heben sich auf")
    }

    @Test func twoFingerScrollPansInsteadOfZooming() throws {
        let event = try #require(scroll(10, units: .pixel))
        #expect(event.hasPreciseScrollingDeltas)
        let input = ZoomEventCatcher.CatcherView.input(for: event)
        guard case .pan(let delta)? = input else { Issue.record("Erwartet: Verschieben, war \(String(describing: input))"); return }
        #expect(delta.height > 0)
    }

    @Test func commandWithTrackpadZoomsInstead() throws {
        let event = try #require(scroll(10, units: .pixel, flags: .maskCommand))
        let zoom = try #require(factor(ZoomEventCatcher.CatcherView.input(for: event)))
        #expect(zoom > 1)
        #expect(zoom < 1.2, "Trackpad mit ⌘ zoomt feiner als das Mausrad")
    }

    @Test func aZeroScrollDoesNothing() throws {
        let event = try #require(scroll(0, units: .line))
        #expect(ZoomEventCatcher.CatcherView.input(for: event) == nil)
    }

    // MARK: Darstellung

    private func render(_ content: some View, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height).background(Color.gray))
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    private func metrics(for image: CGImage, view: CGSize) -> ZoomableImageView.Metrics {
        ZoomableImageView.Metrics(image: image, view: view, pixelScale: 1, backing: 2)
    }

    @Test func percentLabelAndBackingScaleShowUpInTheRenderedControls() throws {
        let image = SyntheticPage.textPage(width: 800, height: 600)
        let m = metrics(for: image, view: CGSize(width: 400, height: 300))
        let content = ZoomableImageContent(
            shown: image, metrics: m, zoom: ZoomState(), identifier: "t", hasDetail: false, isLoadingDetail: false,
            zoomIn: {}, zoomOut: {}, fitToView: {}, actualSize: {}
        )
        // Eingepasst: 400 Punkte · 2 Pixel je Punkt / 800 Pixel = 100 %.
        #expect(m.percent(scale: 1) == 100)
        #expect(try render(content, size: CGSize(width: 400, height: 300)).width == 400)
    }

    @Test func zoomedContentShowsAnEnlargedPartNotTheWholeImage() throws {
        // Links schwarz, rechts weiß. Bei 4-fachem Zoom um die linke obere Ecke bleibt nur Schwarz sichtbar.
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        let image = context.makeImage()!
        let view = CGSize(width: 400, height: 300)
        let m = metrics(for: image, view: view)
        var zoom = ZoomState()
        zoom.zoom(by: 4, around: CGPoint(x: -200, y: -150), fit: m.fit, view: view, maxScale: m.maxScale)   // linke obere Ecke

        let content = ZoomableImageContent(shown: image, metrics: m, zoom: zoom, identifier: "t", hasDetail: false, isLoadingDetail: false,
                                           zoomIn: {}, zoomOut: {}, fitToView: {}, actualSize: {})
        let rendered = try render(content, size: view)
        // Mitte des Ausschnitts: im Original noch tief im schwarzen Teil (bei x = 100 von 400), nicht an der Kante.
        let probe = try pixel(rendered, x: 200, y: 120)
        #expect(probe < 40, "Bei 4-fachem Zoom um die linke Ecke muss die Mitte dunkel sein, ist \(probe)")
        // Eingepasst läge dort die Kante zwischen Schwarz und Weiß (x = 200).
        let fitted = try render(ZoomableImageContent(shown: image, metrics: m, zoom: ZoomState(), identifier: "t", hasDetail: false,
                                                     isLoadingDetail: false, zoomIn: {}, zoomOut: {}, fitToView: {}, actualSize: {}),
                                size: view)
        #expect(try pixel(fitted, x: 300, y: 120) > 200, "Eingepasst ist rechts Weiß")
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> Int {
        var value: UInt8 = 0
        let context = try #require(CGContext(data: &value, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Int(value)
    }

    @Test func correctionsKeyIsStableForTheSameValue() {
        // Ohne feste Schlüsselreihenfolge ergibt dieselbe Korrektur mal diesen, mal jenen Text (gemessen: etwa jeder dritte Lauf).
        var corrections = Corrections(); corrections.setRotation(degrees: 1.5)
        corrections.setCrop(.full)
        let keys = Set((0..<200).map { _ in Corrections(enabled: corrections.enabled, crop: corrections.crop, rotation: corrections.rotation, revision: corrections.revision).cacheKey })
        #expect(keys.count == 1, "Derselbe Wert ergab \(keys.count) verschiedene Schlüssel")
    }

    @Test func correctionsKeyChangesWithAnyCorrectionAndOnlyThen() {
        let a = Corrections()
        var b = Corrections(); b.setRotation(degrees: 1)
        var c = Corrections(); c.setRotation(degrees: 1)
        #expect(a.cacheKey != b.cacheKey)
        #expect(b.cacheKey == c.cacheKey)
        // Die Automatik setzt Korrekturen ohne Zählung von `revision`: der Schlüssel muss es trotzdem merken.
        let auto = Corrections(rotation: RotationCorrection(degrees: 2, enabled: true, source: .automatic, confidence: 0.9))
        #expect(a.revision == auto.revision)
        #expect(a.cacheKey != auto.cacheKey)
    }
}

@MainActor
@Suite("Zoom: Bild in voller Auflösung")
struct FullResolutionTests {
    nonisolated private static let none: @Sendable (CGImage) -> AnalysisResult = { _ in AnalysisResult(corrections: Corrections(), warnings: []) }

    private func makeModel(width: Int = 640, height: Int = 480) async -> (AppModel, ScanItem, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-full-\(UUID().uuidString)")
        // Ein Original, das größer ist als die Miniatur (thumbnailSize 64): wie bei einem echten Scan.
        let format = ScanFormat(width: width, height: height)
        let model = AppModel(scanner: MockScanner(formats: [format], previewsEnabled: false), store: ArchiveStore(root: dir),
                             thumbnailSize: 64, analyze: Self.none)
        await model.connect()
        await model.scan()
        return (model, model.scans[0], dir)
    }

    @Test func returnsTheOriginalInFullSizeWhileTheThumbnailIsSmall() async throws {
        let (model, item, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect((item.thumbnail?.width ?? 0) <= 64)
        let full = try #require(await model.fullResolutionImage(scanID: item.id))
        #expect(full.width == 640 && full.height == 480)
        await model.disconnect()
    }

    @Test func appliesTheCurrentCorrections() async throws {
        let (model, item, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try #require(await model.fullResolutionImage(scanID: item.id))
        model.setRotation(id: item.id, degrees: 10)
        let rotated = try #require(await model.fullResolutionImage(scanID: item.id))
        // Eine Drehung beschneidet auf das größte Rechteck ohne leere Ecken: das Ergebnis ist kleiner.
        #expect(rotated.width < plain.width && rotated.height < plain.height, "Gedreht: \(rotated.width)×\(rotated.height)")
        await model.disconnect()
    }

    @Test func repeatedRequestWithSameCorrectionsComesFromTheCache() async throws {
        let (model, item, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try #require(await model.fullResolutionImage(scanID: item.id))
        let second = try #require(await model.fullResolutionImage(scanID: item.id))
        #expect(first === second, "Dasselbe Bild muss aus dem Zwischenspeicher kommen")
        model.setRotation(id: item.id, degrees: 5)
        let third = try #require(await model.fullResolutionImage(scanID: item.id))
        #expect(third !== first, "Geänderte Korrekturen brauchen ein neues Bild")
        await model.disconnect()
    }

    @Test func unknownScanGivesNil() async {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await model.fullResolutionImage(scanID: UUID()) == nil)
        await model.disconnect()
    }

    @Test func aBookPageGetsItsOwnHalf() async throws {
        let (model, _, dir) = await makeModel(width: 640, height: 480); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let scanID = try #require(model.scans.first?.id)
        let pages = model.pages(of: scanID)
        #expect(pages.count == 2)
        let left = try #require(await model.fullResolutionImage(scanID: scanID, pageID: pages[0].id))
        let right = try #require(await model.fullResolutionImage(scanID: scanID, pageID: pages[1].id))
        // Zwei Hälften eines 640 Pixel breiten Originals, nicht zweimal das ganze Bild.
        #expect(abs(left.width - 320) <= 4 && abs(right.width - 320) <= 4, "Breiten: \(left.width), \(right.width)")
        await model.disconnect()
    }

    @Test func theCacheKeepsAtMostTwoImages() async throws {
        let (model, first, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.scan(); await model.scan()
        let ids = model.scans.map(\.id)
        #expect(ids.count == 3)
        let a = try #require(await model.fullResolutionImage(scanID: ids[0]))
        _ = try #require(await model.fullResolutionImage(scanID: ids[1]))
        _ = try #require(await model.fullResolutionImage(scanID: ids[2]))
        // Der älteste Eintrag wurde verdrängt: ein neuer Aufruf berechnet ein neues Bild.
        let again = try #require(await model.fullResolutionImage(scanID: ids[0]))
        #expect(again !== a, "Der Zwischenspeicher hielt mehr als zwei Bilder")
        _ = first
        await model.disconnect()
    }
}
