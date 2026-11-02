import ArchiveKit
import CoreGraphics
import Foundation
import Observation
import ScannerKit

/// Ein gespeicherter Scan mit Miniatur für die Anzeige.
public struct ScanItem: Identifiable, @unchecked Sendable {
    public let record: ScanRecord
    public let thumbnail: CGImage?
    public var id: UUID { record.id }
}

/// Zustand und Abläufe der Oberfläche. Kennt weder SwiftUI noch die Hardware, nur `ScannerPort` und `ArchiveStore`.
@MainActor
@Observable
public final class AppModel {
    public enum Status: Equatable {
        case disconnected
        case connecting
        case ready
        case capturing
        case failed(String)
    }

    public private(set) var status: Status = .disconnected
    public private(set) var device: DeviceInfo?
    public private(set) var previewImage: CGImage?
    public private(set) var scans: [ScanItem] = []
    public private(set) var message: String?
    public private(set) var captureFormat: ScanFormat?
    /// Dauer des letzten Scans vom Tastendruck bis zur archivierten Miniatur, ohne den Neustart der Vorschau.
    public private(set) var lastScanDuration: Duration?

    public var archiveURL: URL { store.root }
    public var lastScan: ScanItem? { scans.first }

    private let scanner: any ScannerPort
    private let store: ArchiveStore
    private let thumbnailSize: Int
    private var session: (any ScanSession)?
    private var previewTask: Task<Void, Never>?

    public init(scanner: any ScannerPort, store: ArchiveStore, thumbnailSize: Int = 1600) {
        self.scanner = scanner
        self.store = store
        self.thumbnailSize = thumbnailSize
    }

    // MARK: Verbinden

    /// Verbindet den Scanner, öffnet die Sitzung im Aufnahmeformat und lädt vorhandene Scans.
    /// Die Vorschau kommt aus derselben Sitzung wie die Aufnahme.
    public func connect() async {
        guard status != .connecting, status != .capturing, session == nil else { return }
        status = .connecting
        message = nil
        do {
            device = try await scanner.connect()
            let formats = try await scanner.availableFormats()
            guard let format = Self.captureFormat(from: formats) else { throw ScannerError.deviceNotFound }
            captureFormat = format
            await loadExistingScans()
            let opened = try await scanner.openSession(format: format, settings: .archival)
            session = opened
            startPreview(from: opened)
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Beendet die Sitzung und setzt die Geräteeinstellungen zurück. Vor dem Beenden der App aufrufen.
    public func disconnect() async {
        previewTask?.cancel()
        previewTask = nil
        let closing = session
        session = nil
        await closing?.close()
        previewImage = nil
        status = .disconnected
    }

    /// Format: Aufnahme in 5696x4272, falls angeboten, sonst das größte. Nicht blind das größte,
    /// weil die Stufen darüber vom Gerät hochgerechnet und nachgeschärft werden (docs/feasibility.adoc).
    static func captureFormat(from formats: [ScanFormat]) -> ScanFormat? {
        formats.first { $0.width == 5696 && $0.height == 4272 }
            ?? formats.max { $0.width * $0.height < $1.width * $1.height }
    }

    // MARK: Vorschau

    private func startPreview(from session: any ScanSession) {
        previewTask?.cancel()
        previewTask = Task {
            for await frame in session.previewFrames {
                if Task.isCancelled { break }
                self.previewImage = frame.image
            }
        }
    }

    // MARK: Scannen

    /// Nimmt das nächste Bild der laufenden Sitzung in voller Auflösung auf und archiviert das Original.
    public func scan() async {
        guard status == .ready, let session else { return }
        status = .capturing
        message = nil
        let started = ContinuousClock.now
        do {
            let capture = try await session.capture()
            let record = try store.store(capture)
            let store = self.store, size = thumbnailSize
            let thumb = await Task.detached { store.thumbnail(for: record, maxPixelSize: size) }.value
            scans.insert(ScanItem(record: record, thumbnail: thumb), at: 0)
            lastScanDuration = ContinuousClock.now - started
            status = .ready
        } catch {
            message = error.localizedDescription
            status = .ready
        }
    }

    // MARK: Archiv

    private func loadExistingScans() async {
        let store = self.store, size = thumbnailSize
        let items: [ScanItem] = await Task.detached {
            let records = (try? store.allRecords()) ?? []
            return records.suffix(20).reversed().map { ScanItem(record: $0, thumbnail: store.thumbnail(for: $0, maxPixelSize: size)) }
        }.value
        scans = items
    }
}
