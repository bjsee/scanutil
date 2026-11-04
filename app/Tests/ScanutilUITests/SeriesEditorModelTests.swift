import ArchiveKit
import Foundation
import ImagingKit
import Testing
@testable import ScanutilUI

@MainActor
@Suite("Serie bearbeiten: Filter und Blättern")
struct SeriesEditorModelTests {
    /// Fünf Seiten: 1 sicher, 2 Drehung unsicher, 3 Falz unsicher, 4 Hände entfernt (nur Hinweis), 5 unsicher, aber geprüft.
    private func document() -> ScanDocument {
        func page(_ analysis: PageAnalysis, region: PageRegion = .whole, rotation: Double = 0, rotationConfidence: Double = 1, hands: Bool = false) -> DocumentPage {
            var c = Corrections()
            c.rotation = RotationCorrection(degrees: rotation, enabled: rotationConfidence >= 0.6, source: .automatic, confidence: rotationConfidence)
            if hands { c.handRemoval = HandRemovalCorrection(enabled: true, source: .automatic, confidence: 1, mask: Data([1])) }
            return DocumentPage(scanID: UUID(), region: region, corrections: c, analysis: analysis)
        }
        let sure = PageAnalysis(outerDetected: true, outerPlausibility: 0.9)
        var doc = ScanDocument(title: "T")
        doc.append(page(sure))
        doc.append(page(sure, rotation: 2.5, rotationConfidence: 0.3))
        doc.append(page(PageAnalysis(outerDetected: true, outerPlausibility: 0.9, gutterConfidence: 0.3, isSpread: true), region: .left))
        doc.append(page(PageAnalysis(outerDetected: true, outerPlausibility: 0.9, handCoverage: 0.04, handMarkers: 1), hands: true))
        var reviewed = page(PageAnalysis(outerDetected: true, outerPlausibility: 0.2))
        reviewed.reviewedKey = reviewed.corrections.cacheKey
        doc.append(reviewed)
        return doc
    }

    private func visible(_ filter: EditorFilter, _ doc: ScanDocument) -> [Int] {
        let editor = SeriesEditorModel(); editor.filter = filter
        let review = DocumentReview(doc)
        return editor.visiblePages(of: doc, review: review).compactMap { p in doc.pages.firstIndex { $0.id == p.id }.map { $0 + 1 } }
    }

    @Test func allShowsEverythingInOrder() { #expect(visible(.all, document()) == [1, 2, 3, 4, 5]) }

    @Test func onlyUncertainHidesSureAndReviewedPagesAndNotesOnly() {
        #expect(visible(.uncertain, document()) == [2, 3], "1 sicher, 4 nur Hinweis, 5 schon geprüft")
    }

    @Test func kindFiltersLookAtTheFindingsRegardlessOfReviewedState() {
        let doc = document()
        #expect(visible(.rotation, doc) == [2])
        #expect(visible(.crop, doc) == [3, 5], "Falz und Rand, auch die geprüfte Seite")
        #expect(visible(.hands, doc) == [4])
        #expect(visible(.manual, doc) == [])
    }

    @Test func countsMatchWhatTheFilterShows() {
        let doc = document(), review = DocumentReview(doc), editor = SeriesEditorModel()
        for filter in EditorFilter.allCases {
            #expect(editor.count(filter, document: doc, review: review) == visible(filter, doc).count, "\(filter)")
        }
    }

    @Test func steppingStaysInsideTheVisiblePages() {
        let doc = document(), editor = SeriesEditorModel()
        let pages = Array(doc.pages[1...2])
        editor.step(1, in: pages)
        #expect(editor.selectedPageID == pages[0].id, "Ohne Auswahl: die erste sichtbare")
        editor.step(1, in: pages); #expect(editor.selectedPageID == pages[1].id)
        editor.step(1, in: pages); #expect(editor.selectedPageID == pages[1].id, "Am Ende bleibt es")
        editor.step(-1, in: pages); editor.step(-1, in: pages); #expect(editor.selectedPageID == pages[0].id)
        editor.step(1, in: []); #expect(editor.selectedPageID == pages[0].id, "Leere Liste ändert nichts")
    }

    @Test func nextNeedingAttentionWrapsAroundAndSkipsReviewed() {
        let doc = document(), review = DocumentReview(doc), editor = SeriesEditorModel()
        editor.selectedPageID = doc.pages[2].id
        editor.selectNextNeedingAttention(in: doc, review: review)
        #expect(editor.selectedPageID == doc.pages[1].id, "Nach 3 kommt nichts mehr, also von vorn: 2")
        editor.selectNextNeedingAttention(in: doc, review: review)
        #expect(editor.selectedPageID == doc.pages[2].id)
    }

    @Test func nextNeedingAttentionKeepsTheSelectionWhenAllIsDone() {
        var doc = document()
        for i in doc.pages.indices { doc.pages[i].reviewedKey = doc.pages[i].corrections.cacheKey }
        let editor = SeriesEditorModel(); editor.selectedPageID = doc.pages[0].id
        editor.selectNextNeedingAttention(in: doc, review: DocumentReview(doc))
        #expect(editor.selectedPageID == doc.pages[0].id)
    }

    // MARK: Rahmen ziehen

    private let box = Quad(topLeft: .init(x: 0.2, y: 0.2), topRight: .init(x: 0.8, y: 0.2),
                           bottomRight: .init(x: 0.8, y: 0.8), bottomLeft: .init(x: 0.2, y: 0.8))

    @Test func movingACornerChangesOnlyThatCorner() {
        for corner in QuadCorner.allCases {
            let moved = corner.moved(in: box, to: .init(x: 0.5, y: 0.5))
            #expect(corner.point(of: moved) == NormalizedPoint(x: 0.5, y: 0.5), "\(corner)")
            for other in QuadCorner.allCases where other != corner { #expect(other.point(of: moved) == other.point(of: box), "\(other) bleibt") }
        }
    }

    @Test func aCornerCannotLeaveTheImage() {
        let moved = QuadCorner.topLeft.moved(in: box, to: .init(x: -0.3, y: 1.7))
        #expect(moved.topLeft == NormalizedPoint(x: 0, y: 1))
    }

    @Test func theImageFitsCenteredAndWholeIntoTheView() {
        let wide = CropEditor.fit(CGSize(width: 2000, height: 1000), in: CGSize(width: 400, height: 400))
        #expect(wide == CGRect(x: 0, y: 100, width: 400, height: 200))
        let tall = CropEditor.fit(CGSize(width: 1000, height: 2000), in: CGSize(width: 400, height: 400))
        #expect(tall == CGRect(x: 100, y: 0, width: 200, height: 400))
        #expect(CropEditor.fit(.zero, in: CGSize(width: 10, height: 10)) == .zero)
    }

    @Test func screenAndNormalizedPointsConvertBackAndForth() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 400)
        let n = NormalizedPoint(x: 0.25, y: 0.75)
        let screen = CropEditor.point(n, rect)
        #expect(screen == CGPoint(x: 150, y: 350))
        #expect(CropEditor.normalized(screen, rect) == n)
        #expect(CropEditor.normalized(CGPoint(x: 100, y: 50), rect) == NormalizedPoint(x: 0, y: 0))
        #expect(CropEditor.normalized(CGPoint(x: 1, y: 1), .zero) == NormalizedPoint(x: 0, y: 0), "Leeres Rechteck teilt nicht durch null")
    }
}
