import Testing
import Foundation
import ScannerKit
@testable import ArchiveKit

@Suite("ArchiveStore")
struct ArchiveStoreTests {
    private func makeStore() throws -> (ArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-test-\(UUID().uuidString)")
        return (ArchiveStore(root: dir), dir)
    }

    private func sampleCapture() async throws -> Capture {
        let session = try await MockScanner().openSession(format: ScanFormat(width: 320, height: 240), settings: .archival)
        defer { Task { await session.close() } }
        return try await session.capture()
    }

    @Test func storesOriginalWithChecksum() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try await sampleCapture()
        let record = try store.store(capture)

        let stored = try Data(contentsOf: store.originalURL(for: record))
        #expect(stored == capture.imageData)
        #expect(record.original.sha256.count == 64)
        #expect(record.original.bytes == capture.imageData.count)
        #expect(record.original.width == 320)
        #expect(try store.verify(record))
    }

    @Test func originalIsReadOnly() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let record = try store.store(try await sampleCapture())
        let attributes = try FileManager.default.attributesOfItem(atPath: store.originalURL(for: record).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o444)
    }

    @Test func neverOverwritesOriginal() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let capture = try await sampleCapture()
        _ = try store.store(capture, id: id)
        #expect(throws: ArchiveError.self) { _ = try store.store(capture, id: id) }
    }

    @Test func verifyDetectsTampering() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let record = try store.store(try await sampleCapture())
        let url = store.originalURL(for: record)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        var data = try Data(contentsOf: url); data[data.count / 2] ^= 0xFF
        try data.write(to: url)
        #expect(try store.verify(record) == false)
    }

    @Test func loadRoundTrips() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let record = try store.store(try await sampleCapture())
        let loaded = try store.load(id: record.id)
        #expect(loaded.original == record.original)
        #expect(loaded.id == record.id)
        #expect(loaded.capture.device == record.capture.device)
        #expect(loaded.capture.requestedFormat == record.capture.requestedFormat)
        #expect(loaded.capture.sharpness == record.capture.sharpness)
        // Zeitpunkte sind als ISO 8601 mit Millisekunden gespeichert, exakte Gleichheit von Date gilt nicht.
        #expect(abs(loaded.capture.capturedAt.timeIntervalSince(record.capture.capturedAt)) < 0.001)
        #expect(abs(loaded.storedAt.timeIntervalSince(record.storedAt)) < 0.001)
    }

    @Test func loadUnknownIdFails() throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        #expect(throws: ArchiveError.notFound(id)) { _ = try store.load(id: id) }
    }

    @Test func allRecordsSortedByStorageTime() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try await sampleCapture()
        let later = try store.store(capture, now: Date(timeIntervalSince1970: 2000))
        let earlier = try store.store(capture, now: Date(timeIntervalSince1970: 1000))
        #expect(try store.allRecords().map(\.id) == [earlier.id, later.id])
    }

    @Test func emptyArchiveHasNoRecords() throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.allRecords().isEmpty)
    }

    @Test func leavesNoTemporaryFiles() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.store(try await sampleCapture())
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("originals").path)
        #expect(names.allSatisfy { !$0.hasSuffix(".tmp") })
    }
}
