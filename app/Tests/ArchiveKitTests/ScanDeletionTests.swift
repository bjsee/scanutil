import Testing
import Foundation
import ScannerKit
import ImagingKit
@testable import ArchiveKit

@Suite("Scan löschen")
struct ScanDeletionTests {
    private func makeStore() -> (ArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-scandel-\(UUID().uuidString)")
        return (ArchiveStore(root: dir), dir)
    }

    private func storeScan(_ store: ArchiveStore, withCorrections: Bool = true) async throws -> ScanRecord {
        let session = try await MockScanner().openSession(format: ScanFormat(width: 320, height: 240), settings: .archival)
        let capture = try await session.capture()
        await session.close()
        let record = try store.store(capture)
        if withCorrections {
            var c = Corrections(); c.setRotation(degrees: 1)
            try store.saveCorrections(c, for: record.id)
        }
        return record
    }

    /// Merkt sich die Reihenfolge der Entsorgung.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        var urls: [URL] { lock.withLock { _urls } }
        func add(_ url: URL) { lock.withLock { _urls.append(url) } }
    }

    @Test func removesOriginalRecordAndCorrections() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let scan = try await storeScan(store)
        let files = store.files(of: scan)
        #expect(files.count == 3)
        let removed = try store.deleteScan(id: scan.id)
        #expect(Set(removed) == Set(files))
        for file in files { #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) existiert noch") }
        #expect(try store.allRecords().isEmpty)
        #expect(throws: ArchiveError.notFound(scan.id)) { _ = try store.load(id: scan.id) }
    }

    @Test func aReadOnlyOriginalCanBeDeleted() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let scan = try await storeScan(store)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.originalURL(for: scan).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o444, "Das Original ist schreibgeschützt")
        try store.deleteScan(id: scan.id)
        #expect(!FileManager.default.fileExists(atPath: store.originalURL(for: scan).path))
    }

    @Test func theOriginalGoesLast() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let scan = try await storeScan(store)
        let recorder = Recorder()
        try store.deleteScan(id: scan.id, disposal: ScanDisposal { recorder.add($0); try FileManager.default.removeItem(at: $0) })
        #expect(recorder.urls.last == store.originalURL(for: scan), "Bricht etwas ab, soll höchstens ein Original ohne Eintrag bleiben")
        #expect(recorder.urls.first?.deletingLastPathComponent().lastPathComponent == "records")
    }

    @Test func aFailureLeavesTheOriginalInPlace() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let scan = try await storeScan(store)
        struct Broken: Error {}
        // Das Entsorgen der Korrekturen scheitert: das Original muss noch da sein, nichts darf halb verloren gehen.
        #expect(throws: Broken.self) {
            try store.deleteScan(id: scan.id, disposal: ScanDisposal { url in
                if url.deletingLastPathComponent().lastPathComponent == "corrections" { throw Broken() }
                try FileManager.default.removeItem(at: url)
            })
        }
        #expect(FileManager.default.fileExists(atPath: store.originalURL(for: scan).path), "Das Original geht nicht verloren")
    }

    @Test func otherScansStayUntouched() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await storeScan(store), b = try await storeScan(store)
        try store.deleteScan(id: a.id)
        #expect(try store.allRecords().map(\.id) == [b.id])
        #expect(try store.verify(b))
        #expect(try store.corrections(for: b.id) != nil)
    }

    @Test func aScanWithoutCorrectionsHasTwoFiles() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let scan = try await storeScan(store, withCorrections: false)
        #expect(store.files(of: scan).count == 2)
        #expect(try store.deleteScan(id: scan.id).count == 2)
    }

    @Test func deletingAnUnknownScanThrows() {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        #expect(throws: ArchiveError.notFound(id)) { try store.deleteScan(id: id) }
    }

    @Test func aTrashLikeDisposalIsReversibleAndTheArchiveIsWholeAgain() async throws {
        // Der Papierkorb-Weg: Dateien wegschieben und mit „Zurücklegen“ wieder an ihren Platz bringen.
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let scan = try await storeScan(store)
        let bin = dir.appendingPathComponent("papierkorb")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let moved = Recorder()
        let pair = ScanDisposal(isRecoverable: true) { url in
            let target = bin.appendingPathComponent(url.deletingLastPathComponent().lastPathComponent + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            moved.add(url)
        }
        #expect(pair.isRecoverable && !ScanDisposal.permanent.isRecoverable && ScanDisposal.trash.isRecoverable)
        let files = try store.deleteScan(id: scan.id, disposal: pair)
        #expect(try store.allRecords().isEmpty)
        // Zurücklegen: jede Datei an ihren alten Platz.
        for file in files {
            let source = bin.appendingPathComponent(file.deletingLastPathComponent().lastPathComponent + "-" + file.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: file)
        }
        let back = try store.load(id: scan.id)
        // Zeitpunkte sind auf Millisekunden gespeichert: verglichen werden Kennung und Original samt Prüfsumme.
        #expect(back.id == scan.id && back.original == scan.original)
        #expect(try store.verify(back), "Die Prüfsumme stimmt nach dem Zurücklegen wieder")
        #expect(try store.corrections(for: scan.id) != nil)
    }
}
