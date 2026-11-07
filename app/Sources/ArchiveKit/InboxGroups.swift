import Foundation

/// Angaben, die nur eine Schnellablage hat: die Namen der Dokumente, nach der Kennung ihrer Gruppe.
public struct InboxInfo: Codable, Equatable, Sendable {
    /// Beschreibung je Gruppe („Tierarztpraxis“); der Dateiname entsteht daraus mit Jahr und Monat.
    public var names: [String: String]

    public init(names: [String: String] = [:]) { self.names = names }
}

/// Die Seiten, die in der Schnellablage ein Dokument bilden. Aufeinanderfolgende Seiten mit derselben Kennung.
public struct PageGroup: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let pageIDs: [UUID]
}

extension DocumentPage {
    /// Die Gruppe der Seite: die eigene Kennung, solange sie nicht zu einer anderen Seite gehört.
    public var effectiveGroupID: UUID { groupID ?? id }
}

extension ScanDocument {
    /// Die Dokumente der Schnellablage in der Reihenfolge der Seiten. Eine Seite für sich ist ein Dokument.
    public var groups: [PageGroup] {
        var result: [PageGroup] = []
        var currentID: UUID?
        var ids: [UUID] = []
        for page in pages {
            let gid = page.effectiveGroupID
            if gid == currentID { ids.append(page.id); continue }
            if let currentID { result.append(PageGroup(id: currentID, pageIDs: ids)) }
            currentID = gid
            ids = [page.id]
        }
        if let currentID { result.append(PageGroup(id: currentID, pageIDs: ids)) }
        return result
    }

    /// Die Gruppe, zu der die Seite gehört.
    public func group(of pageID: UUID) -> PageGroup? { groups.first { $0.pageIDs.contains(pageID) } }

    /// Die Beschreibung des Dokuments, falls eine vergeben ist.
    public func name(of group: PageGroup) -> String? { inbox?.names[group.id.uuidString] }

    /// Gibt dem Dokument eine Beschreibung. Leer entfernt sie.
    public mutating func setName(_ name: String, of groupID: UUID) {
        guard inbox != nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        inbox?.names[groupID.uuidString] = trimmed.isEmpty ? nil : trimmed
        revision += 1
    }

    /// Fasst das Dokument der Seite mit dem davor zusammen. Gibt `false` zurück, wenn es kein davor gibt.
    /// Der Name des vorderen Dokuments gilt dann für beide; der des hinteren fällt weg.
    @discardableResult
    public mutating func mergeWithPrevious(pageID: UUID) -> Bool {
        let all = groups
        guard let index = all.firstIndex(where: { $0.pageIDs.contains(pageID) }), index > 0 else { return false }
        let target = all[index - 1].id, moving = all[index]
        for i in pages.indices where moving.pageIDs.contains(pages[i].id) { pages[i].groupID = target }
        inbox?.names[moving.id.uuidString] = nil
        revision += 1
        return true
    }

    /// Trennt das Dokument vor der Seite auf: Sie und alle folgenden Seiten desselben Dokuments werden ein neues.
    /// Gibt `false` zurück, wenn die Seite die erste ihres Dokuments ist (es gibt nichts zu trennen).
    @discardableResult
    public mutating func splitBefore(pageID: UUID) -> Bool {
        guard let group = group(of: pageID), let at = group.pageIDs.firstIndex(of: pageID), at > 0 else { return false }
        let moving = Set(group.pageIDs[at...])
        for i in pages.indices where moving.contains(pages[i].id) { pages[i].groupID = pageID }
        revision += 1
        return true
    }
}
