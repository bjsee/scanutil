import Testing
import Foundation
import ImagingKit
@testable import ArchiveKit

@Suite("Seiten bewerten")
struct PageReviewTests {
    private let quad = Quad(topLeft: .init(x: 0.14, y: 0.11), topRight: .init(x: 0.46, y: 0.11),
                            bottomRight: .init(x: 0.46, y: 0.72), bottomLeft: .init(x: 0.14, y: 0.72))

    /// Eine Buchseite, wie die Analyse sie anlegt, wenn alles sicher war.
    private func sureBookPage(region: PageRegion = .left) -> DocumentPage {
        var page = DocumentPage(scanID: UUID(), region: region)
        page.corrections.crop = CropCorrection(quad: quad, enabled: true, source: .automatic, confidence: 0.9)
        page.corrections.rotation = RotationCorrection(degrees: 0.4, enabled: true, source: .automatic, confidence: 1)
        page.analysis = PageAnalysis(outerDetected: true, outerPlausibility: 0.95, gutterConfidence: 0.85, isSpread: true)
        return page
    }

    private func kinds(_ review: PageReview) -> [Finding.Kind] { review.findings.map(\.kind) }

    // MARK: Sichere Seite

    @Test func aSurePageHasNoFindingsAndNeedsNoAttention() {
        let review = PageReviewer.review(sureBookPage())
        #expect(review.findings.isEmpty && review.severity == nil && !review.isUncertain && !review.needsAttention)
    }

    // MARK: Wölbung

    private func fanning() -> WarpField {
        var angles: [Float] = []
        for r in 0..<7 { for _ in 0..<3 { angles.append(Float(-0.4 * Double(r))) } }
        return WarpField(columns: 3, rows: 7, angles: angles)!
    }

    @Test func anEqualizedCurvatureIsANoteAndNotAnUncertainty() throws {
        var page = sureBookPage()
        page.corrections.dewarp = DewarpCorrection(enabled: true, source: .automatic, confidence: 1, field: fanning())
        let review = PageReviewer.review(page)
        let finding = try #require(review.findings.first { $0.message.contains("Wölbung") })
        #expect(finding.severity == .note && finding.kind == .rotation)
        #expect(finding.message.contains("2,4°"), "Spanne in Grad mit Komma: \(finding.message)")
        #expect(!review.needsAttention)
    }

    @Test func aMeasuredButSwitchedOffCurvatureIsMentionedAndAManualOneIsListed() throws {
        var page = sureBookPage()
        page.corrections.dewarp = DewarpCorrection(enabled: false, source: .automatic, confidence: 1, field: fanning())
        #expect(PageReviewer.review(page).findings.contains { $0.message.contains("nicht ausgeglichen") })
        page.corrections.setDewarpEnabled(false)
        let review = PageReviewer.review(page)
        #expect(!review.findings.contains { $0.message.contains("nicht ausgeglichen") }, "Von Hand ausgeschaltet ist keine Meldung wert")
        #expect(review.findings.contains { $0.kind == .manual && $0.message.contains("Wölbung") })
        #expect(!PageReviewer.review(sureBookPage()).findings.contains { $0.message.contains("Wölbung") }, "Ohne Messung kein Hinweis")
    }

    // MARK: Falz und Rand

    @Test func aShakyGutterIsAFindingToCheck() {
        var page = sureBookPage()
        page.analysis?.gutterConfidence = 0.39
        let review = PageReviewer.review(page)
        #expect(kinds(review) == [.gutter] && review.severity == .check && review.needsAttention)
        #expect(review.findings[0].message == "Falz unsicher (0,39)")
    }

    @Test func aMissingGutterIsAProblem() {
        var page = sureBookPage()
        page.analysis?.gutterConfidence = nil
        let review = PageReviewer.review(page)
        #expect(review.findings.first?.kind == .gutter && review.severity == .problem)
    }

    @Test func aMissingOuterEdgeIsAProblemAndSaysTheBookCoversCloth() {
        var page = sureBookPage()
        page.analysis?.outerDetected = false
        page.analysis?.outerPlausibility = nil
        let review = PageReviewer.review(page)
        #expect(review.findings.first?.kind == .outer && review.severity == .problem)
        #expect(review.findings.first?.message.contains("Tuch") == true)
    }

    @Test func aLowPlausibilityOfTheOuterEdgeIsToCheck() {
        var page = sureBookPage()
        page.analysis?.outerPlausibility = 0.5
        #expect(kinds(PageReviewer.review(page)) == [.outer])
    }

    @Test func aSinglePageSaysWhenAnUnsureCropIsNotApplied() {
        var page = DocumentPage(scanID: UUID(), region: .whole)
        page.corrections.crop = CropCorrection(quad: quad, enabled: false, source: .automatic, confidence: 0.4)
        page.corrections.rotation = RotationCorrection(degrees: 0, enabled: true, source: .automatic, confidence: 1)
        page.analysis = PageAnalysis(outerDetected: true, outerPlausibility: 0.4)
        let review = PageReviewer.review(page)
        #expect(review.findings.first?.message.hasSuffix("nicht angewendet") == true, "\(review.findings.map(\.message))")
        // Bei einer Buchseite wirkt der Vorschlag trotzdem (PageGeometry): kein Zusatz.
        var book = sureBookPage(); book.analysis?.outerPlausibility = 0.4
        #expect(PageReviewer.review(book).findings.first?.message.contains("nicht angewendet") == false)
    }

    // MARK: Ältere Dokumente ohne Zusammenfassung

    @Test func anOlderPageWithoutAnalysisIsJudgedByItsCropConfidence() {
        // Der Fall aus dem echten Buch: Zuschnitt aus, Sicherheit 0,39, keine Zusammenfassung gespeichert.
        var page = DocumentPage(scanID: UUID(), region: .left)
        page.corrections.crop = CropCorrection(quad: quad, enabled: false, source: .automatic, confidence: 0.392)
        page.corrections.rotation = RotationCorrection(degrees: -0.6, enabled: true, source: .automatic, confidence: 1)
        let review = PageReviewer.review(page)
        #expect(kinds(review) == [.crop] && review.needsAttention)
        #expect(review.findings[0].message == "Zuschnitt oder Falz unsicher (0,39)")
    }

    @Test func anOlderPageWithASureCropHasNoFinding() {
        var page = DocumentPage(scanID: UUID(), region: .right)
        page.corrections.crop = CropCorrection(quad: quad, enabled: true, source: .automatic, confidence: 0.84)
        page.corrections.rotation = RotationCorrection(degrees: 0.1, enabled: true, source: .automatic, confidence: 1)
        #expect(PageReviewer.review(page).findings.isEmpty)
    }

    @Test func aPageWithoutAnyAnalysisIsMarkedPending() {
        let review = PageReviewer.review(DocumentPage(scanID: UUID()))
        #expect(kinds(review) == [.pending] && review.needsAttention)
    }

    // MARK: Drehung

    @Test func anUnsureRotationThatWasNotAppliedIsToCheck() {
        var page = sureBookPage()
        page.corrections.rotation = RotationCorrection(degrees: 2.5, enabled: false, source: .automatic, confidence: 0.3)
        let review = PageReviewer.review(page)
        #expect(kinds(review) == [.rotation] && review.severity == .check)
        #expect(review.findings[0].message.contains("+2,5°"), Comment(rawValue: review.findings[0].message))
    }

    @Test func noMeasurableRotationOnAnIllustrationIsOnlyANote() {
        var page = sureBookPage()
        page.corrections.rotation = RotationCorrection(degrees: -11.3, enabled: false, source: .automatic, confidence: 0)
        let review = PageReviewer.review(page)
        #expect(kinds(review) == [.rotation] && review.severity == .note && !review.needsAttention, "Ein Titelbild ohne Text ist nicht unsicher")
    }

    @Test func aTinyUnsureAngleIsNotWorthAFinding() {
        var page = sureBookPage()
        page.corrections.rotation = RotationCorrection(degrees: 0.1, enabled: false, source: .automatic, confidence: 0.3)
        #expect(PageReviewer.review(page).findings.isEmpty)
    }

    // MARK: Hände

    @Test func removedHandsAreANoteNotUncertainty() {
        var page = sureBookPage()
        page.corrections.handRemoval = HandRemovalCorrection(enabled: true, source: .automatic, confidence: 1, mask: Data([1]))
        page.analysis?.handCoverage = 0.044
        let review = PageReviewer.review(page)
        #expect(kinds(review) == [.hands] && review.severity == .note && !review.isUncertain)
        #expect(review.findings[0].message.contains("4 % des Bildes"), Comment(rawValue: review.findings[0].message))
        #expect(review.has([.hands]) && !review.has([.rotation]))
    }

    @Test func handsDetectedButNotRemovedAreToCheck() {
        var page = sureBookPage()
        page.corrections.handRemoval = HandRemovalCorrection(enabled: false, source: .automatic, confidence: 0.3, mask: Data([1]))
        #expect(PageReviewer.review(page).severity == .check)
        // Vom Nutzer ausgeschaltet: nur ein Hinweis.
        page.corrections.setHandRemovalEnabled(false)
        let manual = PageReviewer.review(page)
        #expect(!manual.isUncertain && manual.has([.manual]))
    }

    // MARK: Von Hand

    @Test func manualChangesAreListedByName() {
        var page = sureBookPage()
        page.corrections.setRotation(degrees: 1.5)
        page.corrections.setCropEnabled(true)
        let review = PageReviewer.review(page)
        let manual = review.findings.first { $0.kind == .manual }
        #expect(manual?.message == "Von Hand geändert: Zuschnitt, Drehung.")
        #expect(manual?.severity == .note)
    }

    // MARK: Geprüft

    @Test func reviewedRemovesAPageFromAttentionButKeepsTheFindings() {
        var page = sureBookPage()
        page.analysis?.gutterConfidence = 0.39
        page.reviewedKey = page.corrections.cacheKey
        let review = PageReviewer.review(page)
        #expect(review.isReviewed && review.isUncertain && !review.needsAttention, "Der Befund bleibt sichtbar, die Seite zählt nicht mehr als offen")
    }

    @Test func anyChangeAfterReviewingMakesThePageUnreviewedAgain() {
        var page = sureBookPage()
        page.analysis?.gutterConfidence = 0.39
        page.reviewedKey = page.corrections.cacheKey
        #expect(page.isReviewed)
        page.corrections.setRotation(degrees: 2)
        #expect(!page.isReviewed)
        #expect(PageReviewer.review(page).needsAttention)
    }

    @Test func aPageThatWasNeverReviewedIsNotReviewed() {
        #expect(!sureBookPage().isReviewed)
        var page = sureBookPage(); page.reviewedKey = nil
        #expect(!page.isReviewed)
    }

    // MARK: Dokument

    @Test func aDocumentReviewCountsAndOrders() {
        var doc = ScanDocument(title: "Buch")
        var unsure = sureBookPage(); unsure.analysis?.gutterConfidence = 0.3
        var reviewed = sureBookPage(); reviewed.analysis?.gutterConfidence = 0.3; reviewed.reviewedKey = reviewed.corrections.cacheKey
        let sure = sureBookPage()
        [sure, unsure, reviewed].forEach { doc.append($0) }
        let review = DocumentReview(doc)
        #expect(review.order == doc.pages.map(\.id))
        #expect(review.uncertainCount == 2 && review.reviewedCount == 1)
        #expect(review.needingAttention == [unsure.id], "Nur die unsichere, nicht geprüfte Seite")
        #expect(review.review(of: sure.id)?.findings.isEmpty == true)
        #expect(review.review(of: UUID()) == nil)
    }

    // MARK: Speichern

    @Test func olderDocumentFilesWithoutAnalysisOrReviewKeyStillLoad() throws {
        let page = DocumentPage(scanID: UUID(), region: .left)
        // So sah eine Seite vor dieser Funktion aus: ohne `analysis` und `reviewedKey`.
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        json.removeValue(forKey: "analysis"); json.removeValue(forKey: "reviewedKey")
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(DocumentPage.self, from: old)
        #expect(decoded.analysis == nil && decoded.reviewedKey == nil && decoded.id == page.id)
    }

    @Test func analysisAndReviewKeyRoundTrip() throws {
        var page = sureBookPage()
        page.analysis?.warnings = ["Der Falz ist unsicher."]
        page.analysis?.handCoverage = 0.05
        page.reviewedKey = page.corrections.cacheKey
        let decoded = try JSONDecoder().decode(DocumentPage.self, from: JSONEncoder().encode(page))
        #expect(decoded == page && decoded.isReviewed)
    }
}
