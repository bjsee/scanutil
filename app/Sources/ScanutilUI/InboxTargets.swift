import Foundation

/// Ein Zielordner der Schnellablage mit einem Pfad und einem Bezeichner, der leer sein darf („Privat“, „Verein“, „Arbeit“).
public struct InboxTarget: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var path: String
    public var label: String

    public init(id: UUID = UUID(), path: String, label: String = "") {
        self.id = id
        self.path = path
        self.label = label
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Was in Listen steht: der Bezeichner, ohne ihn der Name des Ordners.
    public var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let last = url.lastPathComponent
        return last.isEmpty ? path : last
    }
}

/// Die Liste der Zielordner in der Reihenfolge, die der Nutzer festlegt, und welcher gerade gewählt ist.
public struct InboxTargets: Codable, Equatable, Sendable {
    public private(set) var items: [InboxTarget] = []
    public private(set) var activeID: UUID?

    public init() {}

    public var active: InboxTarget? { items.first { $0.id == activeID } }

    public func target(id: UUID) -> InboxTarget? { items.first { $0.id == id } }

    /// Der Pfad in einer Form, die denselben Ordner immer gleich schreibt (ohne `..` und ohne Schrägstrich am Ende).
    static func normalized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// Fügt einen Ordner hinten an. Gibt es ihn schon, bleibt es bei dem einen Eintrag (ein vorhandener Bezeichner wird nicht
    /// überschrieben, ein leerer durch den neuen ersetzt). Das erste Ziel wird gleich das gewählte.
    @discardableResult
    public mutating func add(path: String, label: String = "") -> InboxTarget {
        let normal = Self.normalized(path)
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = items.firstIndex(where: { Self.normalized($0.path) == normal }) {
            if items[index].label.isEmpty { items[index].label = cleaned }
            return items[index]
        }
        let target = InboxTarget(path: normal, label: cleaned)
        items.append(target)
        if activeID == nil { activeID = target.id }
        return target
    }

    /// Entfernt ein Ziel. War es das gewählte, rückt das nächste nach (sonst das vorige), ohne Ziele bleibt keines gewählt.
    public mutating func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        if activeID == id { activeID = items.isEmpty ? nil : items[min(index, items.count - 1)].id }
    }

    /// Schiebt ein Ziel um einen Platz nach oben (`-1`) oder unten (`+1`). Gibt `false` zurück, wenn es schon am Ende steht.
    @discardableResult
    public mutating func move(id: UUID, by offset: Int) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        guard items.indices.contains(target), offset != 0 else { return false }
        items.swapAt(index, target)
        return true
    }

    public mutating func setLabel(_ label: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wählt ein Ziel. Ein unbekanntes ändert nichts.
    public mutating func select(id: UUID) {
        if items.contains(where: { $0.id == id }) { activeID = id }
    }
}
