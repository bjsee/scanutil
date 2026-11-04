import AppKit
import ArchiveKit
import CoreGraphics
import Foundation
import ImageIO
import ImagingKit
import ScannerKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import ScanutilUI

/// Rendert Ansichten in Bilder, ohne Fenster und ohne Klicks. Prüft, dass sie sich aufbauen lassen und nicht leer sind.
/// Ob das Ergebnis gut aussieht, beurteilt man an den geschriebenen Bildern (Ordner aus `SCANUTIL_SNAPSHOT_DIR`).
@MainActor
@Suite("Gerenderte Ansichten")
struct ViewRenderingTests {
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func snapshotDirectory() -> URL {
        let path = ProcessInfo.processInfo.environment["SCANUTIL_SNAPSHOT_DIR"]
        let url = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func render<V: View>(_ view: V, size: CGSize, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let url = snapshotDirectory().appendingPathComponent("\(name).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return image
    }

    private func scanned(_ image: CGImage) async throws -> (AppModel, ScanItem, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-view-\(UUID().uuidString)")
        let model = AppModel(scanner: SyntheticPage.scanner(delivering: image), store: ArchiveStore(root: dir))
        await model.connect()
        await model.scan()
        #expect(await eventually { model.analyzing.isEmpty && model.scans.first?.corrected != nil })
        return (model, try #require(model.scans.first), dir)
    }

    @Test func seriesBarBeforeAndDuringASeries() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-view-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: ArchiveStore(root: dir))
        await model.connect()
        let before = try render(SeriesBar(model: model, nav: Navigator()), size: CGSize(width: 900, height: 44), name: "serienleiste-vorher")
        #expect(before.width >= 1800)

        model.startSeries(title: "Chronik 1524")
        await model.scan()
        let during = try render(SeriesBar(model: model, nav: Navigator()), size: CGSize(width: 900, height: 44), name: "serienleiste-laeuft")
        #expect(during.width >= 1800)
        #expect(model.series?.pages.count == 1)
        await model.disconnect()
    }

    /// Eine künstliche Doppelseite aus zwei Textseiten, geliefert vom Mock; die Analyse ist fest vorgegeben.
    @Test func detailViewForABookScan() async throws {
        let left = SyntheticPage.textPage(width: 800, height: 1100, tiltCounterClockwise: 2)
        let right = SyntheticPage.textPage(width: 800, height: 1100, tiltCounterClockwise: -1.5)
        let context = CGContext(data: nil, width: 1600, height: 1100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(left, in: CGRect(x: 0, y: 0, width: 800, height: 1100))
        context.draw(right, in: CGRect(x: 800, y: 0, width: 800, height: 1100))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-view-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(scanner: SyntheticPage.scanner(delivering: context.makeImage()!), store: ArchiveStore(root: dir),
                             analyzeBook: { _ in
            func c(_ degrees: Double) -> Corrections {
                Corrections(rotation: RotationCorrection(degrees: degrees, enabled: true, source: .automatic, confidence: 0.9))
            }
            return BookAnalysisResult(left: c(2), right: c(-1.5), warnings: ["Der Falz ist unsicher."])
        })
        await model.connect()
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        let id = try #require(model.scans.first?.id)
        let pageIDs = model.pages(of: id).map(\.id)
        #expect(await eventually { pageIDs.allSatisfy { model.pagePreviews[$0] != nil } })
        let item = try #require(model.scans.first)
        let image = try render(ScanDetailView(model: model, item: item), size: CGSize(width: 520, height: 760), name: "detail-doppelseite")
        #expect(image.width >= 1000)
        await model.disconnect()
    }

    @Test func defaultSeriesTitleIsDated() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(SeriesBar.defaultTitle(now: date).hasPrefix("Serie "))
    }

    @Test func detailViewForConfidentScan() async throws {
        let page = SyntheticPage.textPage(width: 1600, height: 1600, tiltCounterClockwise: 8)
        let (model, item, dir) = try await scanned(page); defer { try? FileManager.default.removeItem(at: dir) }
        let image = try render(ScanDetailView(model: model, item: item), size: CGSize(width: 480, height: 720), name: "detail-sicher")
        #expect(image.width >= 900 && image.height >= 1400)
        await model.disconnect()
    }

    @Test func detailViewForUnsureScanShowsReviewBanner() async throws {
        let (model, item, dir) = try await scanned(SyntheticPage.noise(width: 1200, height: 1200)); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(item.corrections.needsReview || !item.warnings.isEmpty)
        try render(ScanDetailView(model: model, item: item), size: CGSize(width: 480, height: 720), name: "detail-unsicher")
        await model.disconnect()
    }

    @Test func thumbnailCellsRender() async throws {
        let (model, item, dir) = try await scanned(SyntheticPage.textPage(width: 1600, height: 1600, tiltCounterClockwise: 5)); defer { try? FileManager.default.removeItem(at: dir) }
        let row = HStack {
            ThumbnailCell(item: item, selected: true, needsReview: false)
            ThumbnailCell(item: item, selected: false, needsReview: true)
        }.padding()
        try render(row, size: CGSize(width: 280, height: 120), name: "miniaturen")
        await model.disconnect()
    }
}
