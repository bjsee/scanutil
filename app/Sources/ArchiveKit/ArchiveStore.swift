import CryptoKit
import Foundation
import ScannerKit

public enum ArchiveError: Error, Equatable, LocalizedError {
    case alreadyExists(String)
    case notFound(UUID)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let path): "Die Datei \(path) existiert bereits und wird nie überschrieben."
        case .notFound(let id): "Der Scan \(id.uuidString) wurde im Archiv nicht gefunden."
        case .unreadable(let path): "Die Datei \(path) konnte nicht gelesen werden."
        }
    }
}

/// Dateibasiertes Archiv. Originale werden nie überschrieben und tragen eine Prüfsumme.
///
/// Aufbau unter dem Stamm:
/// - `originals/<id>.png`: unverändertes Original, schreibgeschützt
/// - `records/<id>.json`: Eintrag mit Prüfsumme und Aufnahmedaten
public struct ArchiveStore: Sendable {
    public let root: URL
    private var originalsDirectory: URL { root.appendingPathComponent("originals", isDirectory: true) }
    private var recordsDirectory: URL { root.appendingPathComponent("records", isDirectory: true) }

    public init(root: URL) {
        self.root = root
    }

    /// Speichert eine Aufnahme als neues Original.
    @discardableResult
    public func store(_ capture: Capture, id: UUID = UUID(), now: Date = Date()) throws -> ScanRecord {
        let fm = FileManager.default
        try fm.createDirectory(at: originalsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)

        let relative = "originals/\(id.uuidString.lowercased()).png"
        let originalURL = root.appendingPathComponent(relative)
        let recordURL = recordURL(for: id)
        guard !fm.fileExists(atPath: originalURL.path) else { throw ArchiveError.alreadyExists(relative) }
        guard !fm.fileExists(atPath: recordURL.path) else { throw ArchiveError.alreadyExists("records/\(id.uuidString.lowercased()).json") }

        // Erst in eine Temporärdatei im selben Ordner schreiben, dann umbenennen. `moveItem` überschreibt nie.
        let temporary = originalsDirectory.appendingPathComponent(".\(id.uuidString).tmp")
        try capture.imageData.write(to: temporary)
        do { try fm.moveItem(at: temporary, to: originalURL) } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: originalURL.path)

        // Zeitpunkte werden auf Millisekunden gerundet, weil die gespeicherte Darstellung nicht feiner ist.
        let metadata = CaptureMetadata(
            device: capture.metadata.device, requestedFormat: capture.metadata.requestedFormat,
            capturedAt: capture.metadata.capturedAt.roundedToMilliseconds, sharpness: capture.metadata.sharpness
        )
        let record = ScanRecord(
            id: id, storedAt: now.roundedToMilliseconds,
            original: .init(path: relative, sha256: Self.sha256(capture.imageData), bytes: capture.imageData.count,
                            width: capture.width, height: capture.height),
            capture: metadata
        )
        let encoder = Self.encoder()
        try encoder.encode(record).write(to: recordURL, options: .withoutOverwriting)
        return record
    }

    public func load(id: UUID) throws -> ScanRecord {
        let url = recordURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ArchiveError.notFound(id) }
        guard let data = try? Data(contentsOf: url) else { throw ArchiveError.unreadable(url.path) }
        return try Self.decoder().decode(ScanRecord.self, from: data)
    }

    public func allRecords() throws -> [ScanRecord] {
        guard FileManager.default.fileExists(atPath: recordsDirectory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: recordsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.map { try Self.decoder().decode(ScanRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.storedAt < $1.storedAt }
    }

    public func originalURL(for record: ScanRecord) -> URL {
        root.appendingPathComponent(record.original.path)
    }

    /// Prüft, ob das Original noch zur gespeicherten Prüfsumme passt.
    public func verify(_ record: ScanRecord) throws -> Bool {
        let url = originalURL(for: record)
        guard let data = try? Data(contentsOf: url) else { throw ArchiveError.unreadable(url.path) }
        return Self.sha256(data) == record.original.sha256 && data.count == record.original.bytes
    }

    // MARK: Hilfen

    private func recordURL(for id: UUID) -> URL {
        recordsDirectory.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// ISO 8601 mit Sekundenbruchteilen, damit Zeitpunkte unverändert wieder eingelesen werden.
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try dateStyle.parse(text)
        }
        return d
    }
}

extension Date {
    var roundedToMilliseconds: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
