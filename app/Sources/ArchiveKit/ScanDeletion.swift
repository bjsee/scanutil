import Foundation

/// Wie die Dateien eines gelöschten Scans entsorgt werden. Austauschbar, damit Tests nicht in den echten Papierkorb schreiben.
public struct ScanDisposal: Sendable {
    let dispose: @Sendable (URL) throws -> Void
    /// Ob sich das Entsorgte wiederholen lässt (Papierkorb). Die Oberfläche sagt dem Nutzer, welcher Fall gilt.
    public let isRecoverable: Bool

    public init(isRecoverable: Bool = false, _ dispose: @escaping @Sendable (URL) throws -> Void) {
        self.isRecoverable = isRecoverable
        self.dispose = dispose
    }

    /// Endgültig entfernen. Für Tests und temporäre Archive.
    public static let permanent = ScanDisposal { try FileManager.default.removeItem(at: $0) }

    /// In den Papierkorb legen: Mit „Zurücklegen“ kommen die Dateien an ihren alten Platz. Erst das Leeren des Papierkorbs
    /// macht es endgültig. So bleibt ein Irrtum bei einer historischen Vorlage reparierbar.
    public static let trash = ScanDisposal(isRecoverable: true) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
}

extension ArchiveStore {
    /// Die Dateien, die zu einem Scan gehören und vorhanden sind: Original, Eintrag mit Prüfsumme und Korrekturen.
    public func files(of record: ScanRecord) -> [URL] {
        let fm = FileManager.default
        let id = record.id.uuidString.lowercased()
        return [
            root.appendingPathComponent("records/\(id).json"),
            root.appendingPathComponent("corrections/\(id).json"),
            originalURL(for: record),
        ].filter { fm.fileExists(atPath: $0.path) }
    }

    /// Löscht einen Scan: Eintrag, Korrekturen und Original. Seiten in Dokumenten, die auf ihn verweisen, muss der Aufrufer
    /// entfernen (siehe `AppModel`), das Archiv kennt die Dokumente nur als Dateien.
    ///
    /// Das Original kommt zuletzt: Bricht etwas ab, bleibt höchstens ein Original ohne Eintrag liegen und geht nicht verloren.
    /// Ein Eintrag ohne Original dagegen sähe aus wie ein beschädigtes Archiv.
    /// - Returns: die entsorgten Dateien.
    @discardableResult
    public func deleteScan(id: UUID, disposal: ScanDisposal = .permanent) throws -> [URL] {
        let record = try load(id: id)
        let files = files(of: record)
        for file in files { try disposal.dispose(file) }
        return files
    }
}
