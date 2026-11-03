import ArchiveKit
import Foundation
import Observation

/// Welche Seiten das Raster des Editors zeigt.
public enum EditorFilter: String, CaseIterable, Identifiable, Sendable {
    case all, uncertain, crop, rotation, hands, manual
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "Alle"
        case .uncertain: "Nur unsichere"
        case .crop: "Zuschnitt und Falz"
        case .rotation: "Drehung"
        case .hands: "Hände"
        case .manual: "Von Hand"
        }
    }

    /// Passt die Seite zum Filter? „Unsicher“ heißt: offener Befund ab Stufe „prüfen“, noch nicht als geprüft abgehakt.
    func matches(_ review: PageReview) -> Bool {
        switch self {
        case .all: true
        case .uncertain: review.needsAttention
        case .crop: review.has([.outer, .gutter, .crop])
        case .rotation: review.has([.rotation])
        case .hands: review.has([.hands])
        case .manual: review.has([.manual])
        }
    }
}

/// Zustand des Editors: Filter, Auswahl, Blättern. Die Seiten selbst gehören dem `AppModel`.
@MainActor @Observable
public final class SeriesEditorModel {
    public var filter: EditorFilter = .all
    public var selectedPageID: UUID?

    public init() {}

    /// Seiten in Dokumentreihenfolge, die der Filter durchlässt.
    public func visiblePages(of document: ScanDocument, review: DocumentReview) -> [DocumentPage] {
        document.pages.filter { page in review.pages[page.id].map(filter.matches) ?? (filter == .all) }
    }

    /// Wie viele Seiten ein Filter durchließe, für die Zahl am Knopf.
    public func count(_ filter: EditorFilter, document: ScanDocument, review: DocumentReview) -> Int {
        document.pages.filter { page in review.pages[page.id].map(filter.matches) ?? (filter == .all) }.count
    }

    /// Die nächste (oder vorige) sichtbare Seite nach der gewählten; am Ende bleibt die Auswahl stehen.
    public func step(_ direction: Int, in pages: [DocumentPage]) {
        guard !pages.isEmpty else { return }
        guard let current = pages.firstIndex(where: { $0.id == selectedPageID }) else { selectedPageID = pages[0].id; return }
        selectedPageID = pages[min(max(current + direction, 0), pages.count - 1)].id
    }

    /// Springt zur nächsten Seite, die noch Aufmerksamkeit braucht — nach „Geprüft“ der natürliche Weg durch die Serie.
    public func selectNextNeedingAttention(in document: ScanDocument, review: DocumentReview) {
        let ids = document.pages.map(\.id)
        let start = ids.firstIndex(of: selectedPageID ?? UUID()).map { $0 + 1 } ?? 0
        let ordered = Array(ids[start...]) + Array(ids[..<start])
        if let next = ordered.first(where: { review.pages[$0]?.needsAttention == true }) { selectedPageID = next }
    }
}
