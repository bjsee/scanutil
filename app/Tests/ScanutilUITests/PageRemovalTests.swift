import ArchiveKit
import ImagingKit
import Foundation
import ScannerKit
import Testing
@testable import ScanutilUI

@MainActor
@Suite("Seiten aus der Serie entfernen")
struct PageRemovalTests {
    private func makeModel() async -> (AppModel, URL) {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-remove-\(UUID().uuidString)")
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: ArchiveStore(root: archive), thumbnailSize: 128,
                             sound: SilentSound(), defaults: nil)
        await model.connect()
        return (model, archive)
    }

    @Test func removesPagesKeepsTheRestAndCanUndo() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Test")
        for _ in 0..<4 { await model.scan() }
        let doc = try #require(model.series)
        let ids = doc.pages.map(\.id)
        #expect(ids.count == 4)
        let removed = model.removePages(documentID: doc.id, pageIDs: [ids[2], ids[3]])
        #expect(removed == 2)
        let after = try #require(model.latestDocument(id: doc.id))
        #expect(after.pages.map(\.id) == [ids[0], ids[1]])
        // gespeichert, nicht nur im Speicher
        let saved = try ArchiveStore(root: dir).loadDocument(id: doc.id)
        #expect(saved.pages.count == 2)
        #expect(model.undoPageRemoval())
        #expect(model.latestDocument(id: doc.id)?.pages.map(\.id) == ids)
        #expect(!model.undoPageRemoval(), "Rückgängig gilt nur einmal")
        await model.disconnect()
    }

    @Test func unknownPagesChangeNothing() async throws {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Test"); await model.scan()
        let doc = try #require(model.series)
        #expect(model.removePages(documentID: doc.id, pageIDs: [UUID()]) == 0)
        #expect(model.undoablePageRemoval == nil)
        await model.disconnect()
    }
}
