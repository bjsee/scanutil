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
    public private(set) var previewFormat: ScanFormat?
    /// Dauer des letzten Scans vom Tastendruck bis zur archivierten Miniatur, ohne den Neustart der Vorschau.
    public private(set) var lastScanDuration: Duration?

    public var archiveURL: URL { store.root }
    public var lastScan: ScanItem? { scans.first }

    private let scanner: any ScannerPort
    private let store: ArchiveStore
    private let thumbnailSize: Int
    private var previewTask: Task<Void, Never>?

    public init(scanner: any ScannerPort, store: ArchiveStore, thumbnailSize: Int = 1600) {
        self.scanner = scanner
        self.store = store
        self.thumbnailSize = thumbnailSize
    }

    // MARK: Verbinden

    /// Verbindet den Scanner, wählt Formate, lädt vorhandene Scans und startet die Vorschau.
    public func connect() async {
        guard status != .connecting, status != .capturing else { return }
        status = .connecting
        message = nil
        do {
            device = try await scanner.connect()
            let formats = try await scanner.availableFormats()
            captureFormat = Self.captureFormat(from: formats)
            previewFormat = Self.previewFormat(from: formats)
            guard captureFormat != nil, previewFormat != nil else { throw ScannerError.deviceNotFound }
            await loadExistingScans()
            status = .ready
            startPreview()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Formate: Aufnahme in 5696x4272, falls angeboten, sonst das größte. Nicht blind das größte,
    /// weil die Stufen darüber vom Gerät hochgerechnet und nachgeschärft werden (docs/feasibility.adoc).
    static func captureFormat(from formats: [ScanFormat]) -> ScanFormat? {
        formats.first { $0.width == 5696 && $0.height == 4272 }
            ?? formats.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Vorschau: ein Format um 1,5 bis 2 Megapixel im Seitenverhältnis 4:3, sonst das nächstkleinere.
    static func previewFormat(from formats: [ScanFormat]) -> ScanFormat? {
        let target = 1536 * 1152
        let candidates = formats.filter { $0.width * 3 == $0.height * 4 }
        let pool = candidates.isEmpty ? formats : candidates
        return pool.min { abs($0.width * $0.height - target) < abs($1.width * $1.height - target) }
    }

    // MARK: Vorschau

    public func startPreview() {
        guard previewTask == nil, let format = previewFormat else { return }
        previewTask = Task { [scanner] in
            do {
                for try await frame in scanner.previewFrames(format: format) {
                    if Task.isCancelled { break }
                    self.previewImage = frame.image
                }
            } catch {
                self.message = error.localizedDescription
            }
            self.previewTask = nil
        }
    }

    public func stopPreview() async {
        let task = previewTask
        task?.cancel()
        await task?.value
        previewTask = nil
    }

    // MARK: Scannen

    /// Hält die Vorschau an, nimmt in voller Auflösung auf (Schärfe 0), archiviert das Original und startet die Vorschau neu.
    public func scan() async {
        guard status == .ready, let format = captureFormat else { return }
        status = .capturing
        message = nil
        let started = ContinuousClock.now
        await stopPreview()
        do {
            let capture = try await scanner.capture(format: format, settings: .archival)
            let record = try store.store(capture)
            let store = self.store, size = thumbnailSize
            let thumb = await Task.detached { store.thumbnail(for: record, maxPixelSize: size) }.value
            scans.insert(ScanItem(record: record, thumbnail: thumb), at: 0)
            lastScanDuration = ContinuousClock.now - started
            status = .ready
        } catch {
            // Das Gerät ist meist noch da, der Fehler gehört an den Anfang der Oberfläche, nicht in einen Dialog.
            message = error.localizedDescription
            status = .ready
        }
        startPreview()
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
