import ArchiveKit
import ExportKit
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

/// Markieren von Seiten im Editor und gemeinsames Ändern: Zuschnitt, Papier aufhellen, Hände entfernen.
@MainActor
@Suite("Seiten markieren und gemeinsam ändern")
struct MarkedPagesTests {
    // MARK: Markieren (Editor-Modell)

    private func document(pages count: Int) -> ScanDocument {
        var doc = ScanDocument(title: "T")
        for _ in 0..<count { doc.append(DocumentPage(scanID: UUID())) }
        return doc
    }

    @Test func togglingMarksAndUnmarksAndTheDocumentOrderIsKept() {
        let doc = document(pages: 5), editor = SeriesEditorModel()
        let ids = doc.pages.map(\.id)
        editor.toggleMark(ids[3]); editor.toggleMark(ids[1])
        #expect(editor.marked(in: doc) == [ids[1], ids[3]], "In der Reihenfolge des Dokuments, nicht des Anklickens")
        editor.toggleMark(ids[1])
        #expect(editor.marked(in: doc) == [ids[3]] && !editor.isMarked(ids[1]))
        editor.clearMarks()
        #expect(editor.marked(in: doc).isEmpty)
    }

    @Test func aRangeRunsFromTheLastMarkedPageOrTheSelectedOneToTheClickedOne() {
        let doc = document(pages: 6), editor = SeriesEditorModel()
        let ids = doc.pages.map(\.id)
        editor.toggleMark(ids[1])
        editor.markRange(to: ids[4], in: ids)
        #expect(editor.marked(in: doc) == Array(ids[1...4]))
        // Ohne vorherige Markierung beginnt der Bereich bei der gewählten Seite, und rückwärts geht es auch.
        let other = SeriesEditorModel(); other.selectedPageID = ids[4]
        other.markRange(to: ids[2], in: ids)
        #expect(other.marked(in: doc) == Array(ids[2...4]))
    }

    @Test func markingEverythingTheFilterShowsAndMarksOfRemovedPagesDropOut() {
        var doc = document(pages: 4); let editor = SeriesEditorModel()
        let ids = doc.pages.map(\.id)
        editor.mark(Array(ids[0..<3]))
        #expect(editor.marked(in: doc).count == 3)
        doc.removePage(id: ids[1])
        #expect(editor.marked(in: doc) == [ids[0], ids[2]], "Eine entfernte Seite zählt nicht mehr")
    }

    // MARK: Gemeinsam ändern (AppModel)

    private func makeModel() async -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-marked-\(UUID().uuidString)")
        var first = Corrections()
        first.tone = ToneCorrection(enabled: true, source: .automatic)
        let c = first
        let spread = PageAnalysis(outerDetected: true, outerPlausibility: 0.9, gutterConfidence: 0.9, isSpread: true, warnings: [])
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: ArchiveStore(root: dir), thumbnailSize: 128,
                             analyzeBook: { _ in BookAnalysisResult(left: c, right: c, warnings: [], analysis: spread) },
                             sound: SilentSound(), defaults: nil)
        await model.connect()
        return (model, dir)
    }

    private func waitForAnalysis(_ model: AppModel) async {
        for _ in 0..<160 {
            if model.series?.pages.allSatisfy({ $0.analysis != nil }) == true { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Eine Buchserie aus zwei Aufnahmen (vier Seiten), die Aufhellen an haben.
    private func bookSeries(_ model: AppModel) async throws -> ScanDocument {
        model.startSeries(title: "Buch", book: true)
        await model.scan(); await model.scan(); await waitForAnalysis(model)
        return try #require(model.series)
    }

    @Test func toneIsSwitchedOnlyOnTheGivenPagesAndTheCountSaysHowManyChanged() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await bookSeries(model)
        let ids = doc.pages.map(\.id)
        #expect(doc.pages.allSatisfy { $0.corrections.tone.enabled })

        let changed = model.updatePages(documentID: doc.id, pageIDs: [ids[0], ids[2]]) { _, c in
            guard c.tone.enabled != false else { return }
            c.setToneEnabled(false)
        }
        #expect(changed == 2)
        let after = try #require(model.latestDocument(id: doc.id))
        #expect(after.pages.map { $0.corrections.tone.enabled } == [false, true, false, true])
        #expect(after.pages[0].corrections.tone.source == .manual && after.pages[1].corrections.tone.source == .automatic)
        // Auf der Platte.
        let saved = try ArchiveStore(root: dir).loadDocument(id: doc.id)
        #expect(saved.pages.map { $0.corrections.tone.enabled } == [false, true, false, true])

        // Nochmal dasselbe: nichts zu tun, und nichts wird als „von Hand“ markiert.
        let again = model.updatePages(documentID: doc.id, pageIDs: [ids[0], ids[2]]) { _, c in
            guard c.tone.enabled != false else { return }
            c.setToneEnabled(false)
        }
        #expect(again == 0)
        #expect(model.updatePages(documentID: doc.id, pageIDs: [UUID()]) { _, _ in } == 0, "Unbekannte Seiten ändern nichts")
        await model.disconnect()
    }

    @Test func halfOfThePictureGivesTheLeftAndRightHalfOnBookPagesAndTheWholePictureOnSinglePages() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await bookSeries(model)
        let ids = doc.pages.map(\.id)
        let n = model.updatePages(documentID: doc.id, pageIDs: ids) { page, c in
            c.setCrop(page.region == .whole ? .full : PageGeometry.half(of: .full, region: page.region))
        }
        #expect(n == 4)
        let after = try #require(model.latestDocument(id: doc.id))
        for page in after.pages {
            #expect(page.corrections.crop.enabled && page.corrections.crop.source == .manual)
            #expect(page.corrections.crop.quad == PageGeometry.half(of: .full, region: page.region), "Seite \(page.region)")
        }
        #expect(after.pages[0].corrections.crop.quad != after.pages[1].corrections.crop.quad, "Links und rechts sind verschieden")

        await model.disconnect()
    }

    @Test func onSinglePagesItMeansTheWholePictureAndTheScanGetsTheSameCorrections() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Blätter")
        await model.scan()
        let single = try #require(model.series)
        let page = try #require(single.pages.first)
        #expect(model.updatePages(documentID: single.id, pageIDs: [page.id]) { p, c in
            c.setCrop(p.region == .whole ? .full : PageGeometry.half(of: .full, region: p.region))
        } == 1)
        let stored = try ArchiveStore(root: dir).corrections(for: page.scanID)
        #expect(stored?.crop.quad == .full && stored?.crop.source == .manual, "Bei einer Einzelseite gilt es auch für den Scan")
        await model.disconnect()
    }

    @Test func handsAreOnlyChangedWhereTheyWereDetected() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await bookSeries(model)
        let ids = doc.pages.map(\.id)
        // Zwei Seiten bekommen eine erkannte, ausgeschaltete Hand-Maske, zwei haben keine.
        for id in [ids[0], ids[1]] {
            model.updatePage(documentID: doc.id, pageID: id) {
                $0.handRemoval = HandRemovalCorrection(enabled: false, source: .automatic, confidence: 1, mask: Data([1]))
            }
        }
        let on = model.updatePages(documentID: doc.id, pageIDs: ids) { _, c in
            guard c.handRemoval.hasMask, c.handRemoval.enabled != true else { return }
            c.setHandRemovalEnabled(true)
        }
        #expect(on == 2, "Nur die beiden Seiten mit erkannten Händen")
        let after = try #require(model.latestDocument(id: doc.id))
        #expect(after.pages.map { $0.corrections.handRemoval.enabled } == [true, true, false, false])
        #expect(after.pages[2].corrections.handRemoval.source == .automatic && !after.pages[2].corrections.handRemoval.hasMask,
                "Seiten ohne Hände bleiben unberührt")
        await model.disconnect()
    }

    // MARK: Drehung für alle markierten

    @Test func anAngleFieldAcceptsCommaPointAndDegreeSignAndLimitsTheValue() {
        #expect(AngleInput.parse("0") == 0)
        #expect(AngleInput.parse("-1,5") == -1.5)
        #expect(AngleInput.parse("+0.25") == 0.25)
        #expect(AngleInput.parse(" 2,5° ") == 2.5)
        #expect(AngleInput.parse("40") == 15, "Auf ±15° begrenzt wie der Regler")
        #expect(AngleInput.parse("-40") == -15)
        #expect(AngleInput.parse("") == nil && AngleInput.parse("abc") == nil && AngleInput.parse("1,2,3") == nil && AngleInput.parse("°") == nil)
        #expect(AngleInput.text(-0.5) == "-0,50°" && AngleInput.text(0) == "+0,00°")
    }

    @Test func theRotationOfSeveralPagesIsSetToTheSameAngleAndTheOthersKeepTheirs() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await bookSeries(model)
        let ids = doc.pages.map(\.id)
        // Jede Seite hat einen anderen automatischen Winkel.
        for (i, id) in ids.enumerated() {
            model.updatePage(documentID: doc.id, pageID: id) {
                $0.rotation = RotationCorrection(degrees: Double(i) + 0.5, enabled: true, source: .automatic, confidence: 1)
            }
        }
        let n = model.setRotation(degrees: 0, documentID: doc.id, pageIDs: [ids[0], ids[1], ids[3]])
        #expect(n == 3)
        let after = try #require(model.latestDocument(id: doc.id))
        #expect(after.pages.map { $0.corrections.rotation.degrees } == [0, 0, 2.5, 0])
        #expect(after.pages[0].corrections.rotation.source == .manual && after.pages[0].corrections.rotation.enabled)
        #expect(after.pages[2].corrections.rotation.source == .automatic, "Die nicht markierte Seite bleibt")
        let saved = try ArchiveStore(root: dir).loadDocument(id: doc.id)
        #expect(saved.pages.map { $0.corrections.rotation.degrees } == [0, 0, 2.5, 0], "Gespeichert")

        // Dasselbe nochmal: nichts zu ändern. Ein anderer Winkel ändert wieder alle.
        #expect(model.setRotation(degrees: 0, documentID: doc.id, pageIDs: [ids[0], ids[1], ids[3]]) == 0)
        #expect(model.setRotation(degrees: -0.5, documentID: doc.id, pageIDs: [ids[0], ids[1]]) == 2)
        #expect(model.setRotation(degrees: 99, documentID: doc.id, pageIDs: [ids[0]]) == 1, "Wird auf 15° begrenzt")
        #expect(model.latestDocument(id: doc.id)?.pages[0].corrections.rotation.degrees == 15)
        await model.disconnect()
    }
}
