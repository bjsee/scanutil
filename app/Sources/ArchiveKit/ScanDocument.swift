import Foundation
import ImagingKit

/// Welcher Teil eines Originals eine Seite bildet. Im Buchmodus liefert eine Aufnahme zwei Seiten.
public enum PageRegion: String, Codable, Equatable, Sendable {
    case whole
    case left
    case right
}

/// Eine Seite eines Dokuments. Sie verweist auf ein Original und trägt eigene Korrekturen,
/// weil zwei Seiten desselben Originals unterschiedlich geneigt oder zugeschnitten sein können.
public struct DocumentPage: Codable, Equatable, Identifiable, Sendable {
    /// Stabil, auch wenn sich die Reihenfolge ändert.
    public let id: UUID
    /// Das Original, aus dem die Seite entsteht.
    public let scanID: UUID
    public var region: PageRegion
    public var corrections: Corrections
    /// Seitenbezeichnung, falls sie von der Position abweicht, etwa „Vorsatz“ oder „iv“.
    public var label: String?
    /// Was die Analyse über die Seite wusste (Sicherheiten, Warnungen), damit sich später zeigen lässt, wo sie unsicher war.
    /// Ältere Dokumente haben keine.
    public var analysis: PageAnalysis?
    /// Die Korrekturen (`Corrections.cacheKey`), die der Nutzer als geprüft markiert hat. Ändert sich danach etwas, stimmt der
    /// Schlüssel nicht mehr überein, und die Seite gilt wieder als ungeprüft.
    public var reviewedKey: String?

    public init(id: UUID = UUID(), scanID: UUID, region: PageRegion = .whole,
                corrections: Corrections = .none, label: String? = nil, analysis: PageAnalysis? = nil, reviewedKey: String? = nil) {
        self.id = id
        self.scanID = scanID
        self.region = region
        self.corrections = corrections
        self.label = label
        self.analysis = analysis
        self.reviewedKey = reviewedKey
    }

    /// Ob der Nutzer die Seite in ihrem jetzigen Zustand als geprüft markiert hat.
    public var isReviewed: Bool { reviewedKey != nil && reviewedKey == corrections.cacheKey }
}

/// Beschreibende Angaben zu einem Dokument. Alles ist freiwillig.
public struct DocumentMetadata: Codable, Equatable, Sendable {
    public var author: String?
    /// Entstehungszeit der Vorlage als Text, weil historische Angaben oft ungenau sind („um 1900“).
    public var dateText: String?
    public var signature: String?
    public var keywords: [String]
    public var notes: String?

    public init(author: String? = nil, dateText: String? = nil, signature: String? = nil,
                keywords: [String] = [], notes: String? = nil) {
        self.author = author
        self.dateText = dateText
        self.signature = signature
        self.keywords = keywords
        self.notes = notes
    }
}

/// Ein Buch, eine Akte oder ein Blatt als geordnete Folge von Seiten.
/// Die Reihenfolge steht allein hier: Umordnen, Löschen und Einfügen berühren kein Original.
public struct ScanDocument: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var metadata: DocumentMetadata
    public var pages: [DocumentPage]
    /// Hochgezählt bei jeder Änderung.
    public var revision: Int

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(),
                metadata: DocumentMetadata = .init(), pages: [DocumentPage] = [], revision: Int = 0) {
        self.id = id
        self.title = title
        self.createdAt = createdAt.roundedToMilliseconds
        self.metadata = metadata
        self.pages = pages
        self.revision = revision
    }

    public func page(id: UUID) -> DocumentPage? { pages.first { $0.id == id } }

    /// Hängt eine Seite hinten an, wie der Serienmodus es nach jeder Aufnahme tut.
    public mutating func append(_ page: DocumentPage) {
        pages.append(page)
        revision += 1
    }

    /// Fügt eine Seite an einer Position ein, etwa wenn eine Seite nachgescannt wurde. Die Position wird auf 0…Anzahl begrenzt.
    public mutating func insert(_ page: DocumentPage, at index: Int) {
        pages.insert(page, at: min(max(index, 0), pages.count))
        revision += 1
    }

    /// Entfernt eine Seite aus dem Dokument. Das Original bleibt im Archiv.
    @discardableResult
    public mutating func removePage(id: UUID) -> DocumentPage? {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return nil }
        revision += 1
        return pages.remove(at: index)
    }

    /// Verschiebt eine Seite an eine neue Position. Gibt `false` zurück, wenn es die Seite nicht gibt.
    @discardableResult
    public mutating func movePage(id: UUID, to index: Int) -> Bool {
        guard let from = pages.firstIndex(where: { $0.id == id }) else { return false }
        let page = pages.remove(at: from)
        pages.insert(page, at: min(max(index, 0), pages.count))
        revision += 1
        return true
    }

    /// Ersetzt die Seite durch eine neue an derselben Position, etwa nach einem Neuscan.
    @discardableResult
    public mutating func replacePage(id: UUID, with page: DocumentPage) -> Bool {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return false }
        pages[index] = page
        revision += 1
        return true
    }

    /// Ändert die Korrekturen einer Seite.
    @discardableResult
    public mutating func updateCorrections(pageID: UUID, _ change: (inout Corrections) -> Void) -> Bool {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return false }
        change(&pages[index].corrections)
        revision += 1
        return true
    }
}
