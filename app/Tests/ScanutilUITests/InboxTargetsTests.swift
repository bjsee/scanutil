import ArchiveKit
import CoreGraphics
import ExportKit
import Foundation
import PDFKit
import ScannerKit
import Testing
@testable import ScanutilUI

@Suite("Zielordner: Liste")
struct InboxTargetsListTests {
    @Test func addingKeepsTheOrderAndTheFirstBecomesActive() {
        var list = InboxTargets()
        let a = list.add(path: "/tmp/privat", label: "Privat")
        let b = list.add(path: "/tmp/verein", label: " Verein ")
        #expect(list.items.map(\.id) == [a.id, b.id])
        #expect(list.activeID == a.id, "Das erste Ziel ist gleich gewählt")
        #expect(list.items[1].label == "Verein", "Der Bezeichner wird bereinigt")
    }

    @Test func theSameFolderIsOnlyListedOnce() {
        var list = InboxTargets()
        let a = list.add(path: "/tmp/privat/")
        let again = list.add(path: "/tmp/privat/../privat", label: "Privat")
        #expect(list.items.count == 1 && again.id == a.id)
        #expect(list.items[0].label == "Privat", "Ein leerer Bezeichner wird ergänzt")
        _ = list.add(path: "/tmp/privat", label: "Anders")
        #expect(list.items[0].label == "Privat", "Ein vorhandener Bezeichner bleibt")
    }

    @Test func movingSwapsNeighboursAndStopsAtTheEnds() {
        var list = InboxTargets()
        let a = list.add(path: "/a"), b = list.add(path: "/b"), c = list.add(path: "/c")
        let up = list.move(id: c.id, by: -1)
        #expect(up)
        #expect(list.items.map(\.id) == [a.id, c.id, b.id])
        let down = list.move(id: a.id, by: 1)
        #expect(down)
        #expect(list.items.map(\.id) == [c.id, a.id, b.id])
        let top = list.move(id: c.id, by: -1), bottom = list.move(id: b.id, by: 1), unknown = list.move(id: UUID(), by: 1)
        #expect(!top, "Ganz oben geht es nicht weiter")
        #expect(!bottom, "Ganz unten auch nicht")
        #expect(!unknown)
        #expect(list.items.map(\.id) == [c.id, a.id, b.id])
    }

    @Test func removingTheActiveTargetMovesTheChoiceAlong() {
        var list = InboxTargets()
        let a = list.add(path: "/a"), b = list.add(path: "/b"), c = list.add(path: "/c")
        list.select(id: b.id)
        list.remove(id: b.id)
        #expect(list.items.map(\.id) == [a.id, c.id] && list.activeID == c.id, "Das nächste rückt nach")
        list.remove(id: c.id)
        #expect(list.activeID == a.id, "Am Ende das vorige")
        list.remove(id: a.id)
        #expect(list.items.isEmpty && list.activeID == nil && list.active == nil)
        list.remove(id: UUID())          // unbekannt: nichts passiert
    }

    @Test func removingAnotherTargetKeepsTheChoice() {
        var list = InboxTargets()
        let a = list.add(path: "/a"), b = list.add(path: "/b")
        list.select(id: b.id)
        list.remove(id: a.id)
        #expect(list.activeID == b.id)
    }

    @Test func selectingAnUnknownTargetChangesNothing() {
        var list = InboxTargets()
        let a = list.add(path: "/a")
        list.select(id: UUID())
        #expect(list.activeID == a.id)
    }

    @Test func theNameIsTheLabelOrTheFolderName() {
        #expect(InboxTarget(path: "/Users/x/Dokumente/Verein", label: "Heimatverein").displayName == "Heimatverein")
        #expect(InboxTarget(path: "/Users/x/Dokumente/Verein", label: "  ").displayName == "Verein")
        #expect(InboxTarget(path: "/", label: "").displayName == "/")
    }

    @Test func theListSurvivesEncoding() throws {
        var list = InboxTargets()
        _ = list.add(path: "/a", label: "A"); let b = list.add(path: "/b"); list.select(id: b.id)
        let back = try JSONDecoder().decode(InboxTargets.self, from: JSONEncoder().encode(list))
        #expect(back == list && back.activeID == b.id)
    }
}

@MainActor
@Suite("Zielordner: Schnellablage")
struct InboxTargetsModelTests {
    private func makeModel(defaults: UserDefaults? = nil) async -> (AppModel, URL) {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-targets-\(UUID().uuidString)")
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: ArchiveStore(root: archive), thumbnailSize: 256,
                             recognizer: NoText(), sound: SilentSound(), defaults: defaults)
        await model.connect()
        return (model, archive)
    }

    private struct NoText: TextRecognizer {
        func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] { [] }
    }

    private func dirs() -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory
        return (base.appendingPathComponent("scanutil-privat-\(UUID().uuidString)"), base.appendingPathComponent("scanutil-verein-\(UUID().uuidString)"))
    }

    @Test func eachNewScanGoesToTheTargetThatIsChosenAtThatMoment() async throws {
        let (model, archive) = await makeModel(); defer { try? FileManager.default.removeItem(at: archive) }
        let (p, v) = dirs()
        let privat = model.addInboxTarget(path: p.path, label: "Privat"), verein = model.addInboxTarget(path: v.path, label: "Verein")
        model.startInbox()
        await model.scan()                                  // Privat (gewählt)
        model.selectInboxTarget(id: verein.id)
        await model.scan()                                  // Verein
        await model.scan()                                  // Verein
        model.selectInboxTarget(id: privat.id)
        await model.scan()                                  // Privat
        let doc = try #require(model.series)
        #expect(doc.groups.map { doc.target(of: $0) } == [privat.id, verein.id, verein.id, privat.id])
        await model.disconnect()
    }

    @Test func filingWritesEachDocumentIntoItsOwnFolder() async throws {
        let (model, archive) = await makeModel(); let (p, v) = dirs()
        defer { for u in [archive, p, v] { try? FileManager.default.removeItem(at: u) } }
        let privat = model.addInboxTarget(path: p.path, label: "Privat"), verein = model.addInboxTarget(path: v.path, label: "Verein")
        model.startInbox()
        await model.scan(); model.selectInboxTarget(id: verein.id); await model.scan(); await model.scan()
        let id = try #require(await model.finishInbox())
        var doc = try #require(model.latestDocument(id: id))
        doc.setName("Erster", of: doc.groups[0].id); doc.setName("Zweiter", of: doc.groups[1].id); doc.setName("Dritter", of: doc.groups[2].id)
        model.commit(doc)
        let urls = await model.fileInbox(documentID: id)
        #expect(urls.count == 3)
        func names(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".pdf") }.sorted() }
        let prefix = InboxNaming.prefix(for: Date())
        #expect(names(p) == ["\(prefix) Erster.pdf"], "Privat: \(names(p))")
        #expect(names(v) == ["\(prefix) Dritter.pdf", "\(prefix) Zweiter.pdf"], "Verein: \(names(v))")
        _ = privat
        await model.disconnect()
    }

    @Test func aDocumentCanBeMovedToAnotherTargetAfterwards() async throws {
        let (model, archive) = await makeModel(); let (p, v) = dirs()
        defer { for u in [archive, p, v] { try? FileManager.default.removeItem(at: u) } }
        _ = model.addInboxTarget(path: p.path, label: "Privat"); let verein = model.addInboxTarget(path: v.path, label: "Verein")
        model.startInbox(); await model.scan()
        let id = try #require(await model.finishInbox())
        let group = try #require(model.latestDocument(id: id)?.groups.first)
        model.setInboxGroupTarget(documentID: id, groupID: group.id, targetID: verein.id)
        #expect(model.latestDocument(id: id).flatMap { $0.target(of: $0.groups[0]) } == verein.id)
        model.setInboxGroupTarget(documentID: id, groupID: group.id, targetID: UUID())          // unbekannt: bleibt
        #expect(model.latestDocument(id: id).flatMap { $0.target(of: $0.groups[0]) } == verein.id)
        _ = await model.fileInbox(documentID: id)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: v.path)) ?? []).contains { $0.hasSuffix(".pdf") })
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: p.path)) ?? []).filter { $0.hasSuffix(".pdf") }.isEmpty)
        await model.disconnect()
    }

    @Test func aDeletedTargetFallsBackToTheChosenOne() async throws {
        let (model, archive) = await makeModel(); let (p, v) = dirs()
        defer { for u in [archive, p, v] { try? FileManager.default.removeItem(at: u) } }
        let privat = model.addInboxTarget(path: p.path, label: "Privat"); let verein = model.addInboxTarget(path: v.path, label: "Verein")
        model.selectInboxTarget(id: verein.id)
        model.startInbox(); await model.scan()
        let id = try #require(await model.finishInbox())
        model.removeInboxTarget(id: verein.id)                    // das Ziel des Dokuments ist weg
        #expect(model.inboxTargets.activeID == privat.id)
        let urls = await model.fileInbox(documentID: id)
        #expect(urls.count == 1 && urls[0].path.hasPrefix(p.path), "Ersatzweise das gewählte Ziel: \(urls)")
        await model.disconnect()
    }

    @Test func withoutAnyTargetNothingIsWritten() async throws {
        let (model, archive) = await makeModel(); defer { try? FileManager.default.removeItem(at: archive) }
        model.startInbox(); await model.scan()
        let id = try #require(await model.finishInbox())
        #expect(await model.fileInbox(documentID: id).isEmpty)
        #expect(model.latestDocument(id: id) != nil && model.log.first?.level == .error)
        await model.disconnect()
    }

    @Test func mergingKeepsTheTargetOfTheFirstAndSplittingInheritsIt() async throws {
        let (model, archive) = await makeModel(); defer { try? FileManager.default.removeItem(at: archive) }
        let (p, v) = dirs()
        let privat = model.addInboxTarget(path: p.path, label: "Privat"), verein = model.addInboxTarget(path: v.path, label: "Verein")
        model.startInbox(); await model.scan(); model.selectInboxTarget(id: verein.id); await model.scan()
        let id = try #require(await model.finishInbox())
        let ids = try #require(model.latestDocument(id: id)).pages.map(\.id)
        model.mergeInboxPage(documentID: id, pageID: ids[1])
        var doc = try #require(model.latestDocument(id: id))
        #expect(doc.groups.count == 1 && doc.target(of: doc.groups[0]) == privat.id, "Das vordere Dokument bestimmt das Ziel")
        model.splitInboxPage(documentID: id, pageID: ids[1])
        doc = try #require(model.latestDocument(id: id))
        #expect(doc.groups.count == 2 && doc.groups.allSatisfy { doc.target(of: $0) == privat.id }, "Das abgetrennte Dokument erbt es")
        _ = verein
        await model.disconnect()
    }

    @Test func theListIsSavedAndOldSingleFolderBecomesTheFirstTarget() async {
        let suite = UserDefaults(suiteName: "scanutil-targets-\(UUID().uuidString)")!
        let (first, a1) = await makeModel(defaults: suite); defer { try? FileManager.default.removeItem(at: a1) }
        let x = first.addInboxTarget(path: "/tmp/x", label: "X"); _ = first.addInboxTarget(path: "/tmp/y")
        first.moveInboxTarget(id: x.id, up: false)
        first.selectInboxTarget(id: x.id)
        let (second, a2) = await makeModel(defaults: suite); defer { try? FileManager.default.removeItem(at: a2) }
        #expect(second.inboxTargets == first.inboxTargets, "Liste, Reihenfolge und Wahl bleiben erhalten")
        #expect(second.inboxTargets.items.map(\.label) == ["", "X"])

        // Eine frühere Fassung kannte nur einen Ordner.
        let old = UserDefaults(suiteName: "scanutil-targets-\(UUID().uuidString)")!
        old.set("/tmp/alt", forKey: "inboxDirectory")
        let (migrated, a3) = await makeModel(defaults: old); defer { try? FileManager.default.removeItem(at: a3) }
        #expect(migrated.inboxTargets.items.map(\.path) == ["/tmp/alt"] && migrated.inboxDirectory?.path == "/tmp/alt")
    }
}
