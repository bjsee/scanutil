import Foundation
import ImagingKit

extension ArchiveStore {
    private var correctionsDirectory: URL { root.appendingPathComponent("corrections", isDirectory: true) }

    private func correctionsURL(for id: UUID) -> URL {
        correctionsDirectory.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    /// Korrekturen zu einem Original, oder `nil`, wenn es noch keine gibt.
    public func corrections(for id: UUID) throws -> Corrections? {
        let url = correctionsURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { throw ArchiveError.unreadable(url.path) }
        return try JSONDecoder().decode(Corrections.self, from: data)
    }

    /// Speichert die Korrekturen zu einem vorhandenen Scan. Anders als das Original sind sie änderbar,
    /// geschrieben wird atomar, damit nach einem Absturz keine halbe Datei bleibt.
    public func saveCorrections(_ corrections: Corrections, for id: UUID) throws {
        _ = try load(id: id)
        let fm = FileManager.default
        try fm.createDirectory(at: correctionsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(corrections)
        try data.write(to: correctionsURL(for: id), options: .atomic)
    }
}
