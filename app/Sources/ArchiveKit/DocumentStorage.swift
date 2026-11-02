import Foundation

extension ArchiveStore {
    private var documentsDirectory: URL { root.appendingPathComponent("documents", isDirectory: true) }

    private func documentURL(for id: UUID) -> URL {
        documentsDirectory.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    /// Speichert ein Dokument. Anders als die Originale ist es änderbar, geschrieben wird atomar,
    /// damit nach einem Absturz mitten im Serienmodus keine halbe Datei bleibt.
    /// Jede Seite muss auf ein vorhandenes Original verweisen.
    public func saveDocument(_ document: ScanDocument) throws {
        for page in document.pages { _ = try load(id: page.scanID) }
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        try Self.encoder().encode(document).write(to: documentURL(for: document.id), options: .atomic)
    }

    public func loadDocument(id: UUID) throws -> ScanDocument {
        let url = documentURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ArchiveError.documentNotFound(id) }
        guard let data = try? Data(contentsOf: url) else { throw ArchiveError.unreadable(url.path) }
        return try Self.decoder().decode(ScanDocument.self, from: data)
    }

    public func allDocuments() throws -> [ScanDocument] {
        guard FileManager.default.fileExists(atPath: documentsDirectory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.map { try Self.decoder().decode(ScanDocument.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Scans, die in keinem Dokument vorkommen, etwa verworfene Seiten oder Aufnahmen vor einem Absturz.
    public func unassignedScans() throws -> [ScanRecord] {
        let used = Set(try allDocuments().flatMap { $0.pages.map(\.scanID) })
        return try allRecords().filter { !used.contains($0.id) }
    }
}
