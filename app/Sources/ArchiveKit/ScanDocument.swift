import Foundation
import ImagingKit

/// Welcher Teil eines Originals eine Seite bildet. Im Buchmodus liefert eine Aufnahme zwei Seiten.
public enum PageRegion: String, Codable, Equatable, Sendable {
    case whole
    case left
    case right
}

/// Der zweite Scan einer Seite, die aus zwei Aufnahmen besteht (ein großer Plan, der in zwei Hälften gescannt wurde). Er liegt rechts
/// vom ersten, mit eigenen Korrekturen (quer gescannt, eigener Zuschnitt). Die Hälften überlappen sich meist nicht: Der Schnitt an
/// der Papierkante und etwas Abstand oder Überlappung machen die Naht.
public struct JoinedPart: Codable, Equatable, Sendable {
    public var scanID: UUID
    public var corrections: Corrections
    /// Was die Analyse über den Scan wusste, bevor er mit der Seite verbunden wurde.
    public var analysis: PageAnalysis?
    /// Abstand zwischen den Teilen als Anteil der Breite des ersten Teils. Negativ: Der zweite Teil überlappt den ersten.
    public var gap: Double
    /// Verschiebung des zweiten Teils nach unten als Anteil der Höhe des ersten Teils. Negativ: nach oben.
    public var shift: Double

    public static let gapRange = -0.2...0.2
    public static let shiftRange = -0.2...0.2

    public init(scanID: UUID, corrections: Corrections = .none, analysis: PageAnalysis? = nil, gap: Double = 0, shift: Double = 0) {
        self.scanID = scanID
        self.corrections = corrections
        self.analysis = analysis
        self.gap = gap
        self.shift = shift
    }
}

/// Welcher Scan einer Seite gemeint ist: der erste, oder bei einer verbundenen Seite der zweite (rechts).
public enum PagePart: String, Codable, Sendable, CaseIterable {
    case first, second
}

/// Eine Seite eines Dokuments. Sie verweist auf ein Original und trägt eigene Korrekturen,
/// weil zwei Seiten desselben Originals unterschiedlich geneigt oder zugeschnitten sein können.
public struct DocumentPage: Codable, Equatable, Identifiable, Sendable {
    /// Stabil, auch wenn sich die Reihenfolge ändert.
    public let id: UUID
    /// Das Original, aus dem die Seite entsteht.
    public var scanID: UUID
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
    /// Zu welchem Dokument die Seite in der Schnellablage gehört. Ohne Angabe ist sie ein Dokument für sich;
    /// Seiten mit derselben Kennung bilden zusammen ein Dokument (siehe `ScanDocument.groups`).
    public var groupID: UUID?
    /// Der zweite Scan, wenn die Seite aus zwei Aufnahmen besteht (rechts vom ersten). Sonst `nil`.
    public var joined: JoinedPart?

    public init(id: UUID = UUID(), scanID: UUID, region: PageRegion = .whole,
                corrections: Corrections = .none, label: String? = nil, analysis: PageAnalysis? = nil, reviewedKey: String? = nil,
                groupID: UUID? = nil, joined: JoinedPart? = nil) {
        self.groupID = groupID
        self.joined = joined
        self.id = id
        self.scanID = scanID
        self.region = region
        self.corrections = corrections
        self.label = label
        self.analysis = analysis
        self.reviewedKey = reviewedKey
    }

    /// Ob der Nutzer die Seite in ihrem jetzigen Zustand als geprüft markiert hat. Bei einer verbundenen Seite gehören beide Teile
    /// und die Naht dazu: Ändert sich am zweiten etwas, ist die Seite wieder ungeprüft.
    public var isReviewed: Bool { reviewedKey != nil && reviewedKey == reviewKey }

    /// Was „geprüft“ festhält: die Korrekturen der Seite, bei einer verbundenen auch die des zweiten Teils und die Naht.
    public var reviewKey: String {
        guard let joined else { return corrections.cacheKey }
        return corrections.cacheKey + "|" + joined.corrections.cacheKey + "|\(joined.scanID)|\(joined.gap)|\(joined.shift)"
    }

    /// Alle Scans, aus denen die Seite besteht.
    public var scanIDs: [UUID] { [scanID] + (joined.map { [$0.scanID] } ?? []) }

    /// Die Korrekturen des Teils; für `.second` ohne verbundenen Teil die der Seite.
    public func corrections(of part: PagePart) -> Corrections { part == .second ? (joined?.corrections ?? corrections) : corrections }

    /// Der Scan des Teils; für `.second` ohne verbundenen Teil der erste.
    public func scanID(of part: PagePart) -> UUID { part == .second ? (joined?.scanID ?? scanID) : scanID }

    /// Ob die Seite diesen Scan benutzt, als ersten oder als verbundenen zweiten Teil.
    public func uses(scan id: UUID) -> Bool { scanID == id || joined?.scanID == id }
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
    /// Wann zuletzt etwas am Dokument geändert wurde (Seite, Korrektur, Name). Ältere Dokumente kennen es nicht.
    public var modifiedAt: Date?
    /// Gesetzt bei einer Schnellablage (lose Dokumente, jede Seite zunächst für sich) statt einer Serie.
    public var inbox: InboxInfo?
    /// Die Art der Vorlage (Buch, Dokument, Foto). Ältere Dokumente haben keine: Dann gilt Buch bei Doppelseiten, sonst Dokument.
    public var profile: ScanProfile?
    public var metadata: DocumentMetadata
    public var pages: [DocumentPage]
    /// Hochgezählt bei jeder Änderung.
    public var revision: Int

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), inbox: InboxInfo? = nil, profile: ScanProfile? = nil,
                metadata: DocumentMetadata = .init(), pages: [DocumentPage] = [], revision: Int = 0) {
        self.id = id
        self.title = title
        self.createdAt = createdAt.roundedToMilliseconds
        self.inbox = inbox
        self.profile = profile
        self.metadata = metadata
        self.pages = pages
        self.revision = revision
    }

    public var isInbox: Bool { inbox != nil }

    /// Das Profil, das gilt: das gesetzte, sonst aus den Seiten abgelesen.
    public var effectiveProfile: ScanProfile {
        profile ?? (pages.contains { $0.region != .whole } ? .book : .document)
    }

    /// Der Zeitpunkt der letzten Bearbeitung; ohne Angabe der Anlegezeitpunkt.
    public var lastModified: Date { modifiedAt ?? createdAt }

    /// Vermerkt eine Bearbeitung.
    public mutating func touch(_ date: Date = Date()) { modifiedAt = date.roundedToMilliseconds }

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

    /// Fügt zwei Seiten zu einer zusammen: Der Scan der zweiten wird der rechte Teil der ersten, die zweite Seite verschwindet aus der
    /// Liste. Beide müssen ganze Seiten sein (keine Buchhälften), verschiedene Scans haben und selbst noch nicht verbunden sein.
    @discardableResult
    public mutating func joinPages(first firstID: UUID, second secondID: UUID) -> Bool {
        guard firstID != secondID,
              let a = pages.firstIndex(where: { $0.id == firstID }), let b = pages.firstIndex(where: { $0.id == secondID }),
              pages[a].region == .whole, pages[b].region == .whole,
              pages[a].joined == nil, pages[b].joined == nil, pages[a].scanID != pages[b].scanID else { return false }
        let second = pages[b]
        pages[a].joined = JoinedPart(scanID: second.scanID, corrections: second.corrections, analysis: second.analysis)
        pages.remove(at: b)
        revision += 1
        return true
    }

    /// Trennt eine verbundene Seite wieder: Der zweite Teil wird eine eigene Seite gleich hinter der ersten, mit seinen Korrekturen.
    @discardableResult
    public mutating func unjoinPage(id: UUID) -> Bool {
        guard let index = pages.firstIndex(where: { $0.id == id }), let part = pages[index].joined else { return false }
        pages[index].joined = nil
        pages.insert(DocumentPage(scanID: part.scanID, corrections: part.corrections, analysis: part.analysis, groupID: pages[index].groupID), at: index + 1)
        revision += 1
        return true
    }

    /// Vertauscht links und rechts einer verbundenen Seite: Der zweite Scan wird der erste und umgekehrt, jeder behält seine Korrekturen.
    @discardableResult
    public mutating func swapJoinedParts(id: UUID) -> Bool {
        guard let index = pages.firstIndex(where: { $0.id == id }), let part = pages[index].joined else { return false }
        let first = pages[index]
        pages[index].scanID = part.scanID
        pages[index].corrections = part.corrections
        pages[index].analysis = part.analysis
        pages[index].joined = JoinedPart(scanID: first.scanID, corrections: first.corrections, analysis: first.analysis, gap: part.gap, shift: -part.shift)
        revision += 1
        return true
    }

    /// Ändert die Korrekturen eines Teils einer Seite. `.second` wirkt nur bei einer verbundenen Seite.
    @discardableResult
    public mutating func updateCorrections(pageID: UUID, part: PagePart, _ change: (inout Corrections) -> Void) -> Bool {
        guard part == .second else { return updateCorrections(pageID: pageID, change) }
        guard let index = pages.firstIndex(where: { $0.id == pageID }), pages[index].joined != nil else { return false }
        change(&pages[index].joined!.corrections)
        revision += 1
        return true
    }

    /// Stellt die Naht einer verbundenen Seite ein (Abstand und Höhenversatz, begrenzt auf ±20 %).
    @discardableResult
    public mutating func setSeam(pageID: UUID, gap: Double? = nil, shift: Double? = nil) -> Bool {
        guard let index = pages.firstIndex(where: { $0.id == pageID }), pages[index].joined != nil else { return false }
        if let gap { pages[index].joined!.gap = min(JoinedPart.gapRange.upperBound, max(JoinedPart.gapRange.lowerBound, gap)) }
        if let shift { pages[index].joined!.shift = min(JoinedPart.shiftRange.upperBound, max(JoinedPart.shiftRange.lowerBound, shift)) }
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
