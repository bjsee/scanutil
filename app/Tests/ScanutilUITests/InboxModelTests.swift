import ArchiveKit
import CoreGraphics
import ExportKit
import ImagingKit
import Foundation
import PDFKit
import ScannerKit
import Testing
@testable import ScanutilUI

private struct FakeRecognizer: TextRecognizer {
    let lines: [String]
    func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        lines.enumerated().map { RecognizedLine(text: $1, box: CGRect(x: 0.1, y: 0.9 - Double($0) * 0.05, width: 0.5, height: 0.03)) }
    }
}

private struct FakeDescriber: DescriptionSuggesting {
    let available: Bool
    let answer: String?
    var isAvailable: Bool { available }
    func describe(text: String) async -> String? { answer }
}

@MainActor
@Suite("Schnellablage: Modell")
struct InboxModelTests {
    private func makeModel(lines: [String] = ["Tierarztpraxis Dr. Meier", "Rechnung Nr. 1"], describer: any DescriptionSuggesting = NoDescriber(),
                           directory: Bool = true) async -> (AppModel, URL, URL) {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-inbox-\(UUID().uuidString)")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-inbox-out-\(UUID().uuidString)")
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: ArchiveStore(root: archive), thumbnailSize: 256,
                             recognizer: FakeRecognizer(lines: lines), describer: describer, sound: SilentSound(), defaults: nil)
        if directory { model.inboxDirectory = out }
        await model.connect()
        return (model, archive, out)
    }

    private func clean(_ urls: URL...) { for u in urls { try? FileManager.default.removeItem(at: u) } }

    @Test func startingAnInboxMakesAnInboxDocumentWhereEveryScanIsItsOwnDocument() async throws {
        let (model, a, o) = await makeModel(); defer { clean(a, o) }
        model.startInbox()
        #expect(model.isInboxActive && model.series?.isInbox == true)
        await model.scan(); await model.scan(); await model.scan()
        let doc = try #require(model.series)
        #expect(doc.pages.count == 3 && doc.groups.count == 3, "Jede Aufnahme ein Dokument")
        #expect(doc.pages.allSatisfy { $0.region == .whole })
        await model.disconnect()
    }

    @Test func autoTriggerNeverFiresInAnInbox() async throws {
        let (model, a, o) = await makeModel(); defer { clean(a, o) }
        model.startInbox()
        #expect(model.autoTriggerEnabled)           // der Schalter bleibt an, in der Schnellablage zählt er nicht
        for t in stride(from: 0.0, to: 8.0, by: 0.25) {
            let signature = FrameSignature(cells: [UInt8](repeating: UInt8(t > 3 ? 200 : 20), count: FrameSignature.width * FrameSignature.height))!
            await model.processSeriesFrame(signature, at: t)
        }
        #expect(model.series?.pages.isEmpty == true, "Ohne Nutzer keine Aufnahme")
        await model.disconnect()
    }

    @Test func finishingSuggestsANamePerDocumentFromTheTextWithoutAI() async throws {
        let (model, a, o) = await makeModel(); defer { clean(a, o) }
        model.startInbox()
        await model.scan(); await model.scan()
        let id = try #require(await model.finishInbox())
        #expect(!model.isInboxActive)
        let doc = try #require(model.latestDocument(id: id))
        #expect(doc.groups.count == 2)
        #expect(doc.groups.allSatisfy { doc.name(of: $0) == "Tierarztpraxis Dr. Meier" }, "Regel: erste Zeile, höchstens vier Wörter")
        await model.disconnect()
    }

    @Test func theAIAnswerWinsAndFallsBackToTheRuleWhenItIsEmptyOrUnavailable() async throws {
        let (ai, a1, o1) = await makeModel(describer: FakeDescriber(available: true, answer: "Stadtwerke Jahresabrechnung")); defer { clean(a1, o1) }
        ai.startInbox(); await ai.scan()
        let id = try #require(await ai.finishInbox())
        #expect(ai.latestDocument(id: id).flatMap { $0.name(of: $0.groups[0]) } == "Stadtwerke Jahresabrechnung")
        await ai.disconnect()

        let (empty, a2, o2) = await makeModel(describer: FakeDescriber(available: true, answer: " / ")); defer { clean(a2, o2) }
        empty.startInbox(); await empty.scan()
        let id2 = try #require(await empty.finishInbox())
        #expect(empty.latestDocument(id: id2).flatMap { $0.name(of: $0.groups[0]) } == "Tierarztpraxis Dr. Meier", "Leere KI-Antwort: Regel")
        await empty.disconnect()

        let (off, a3, o3) = await makeModel(describer: FakeDescriber(available: true, answer: "KI")); defer { clean(a3, o3) }
        off.aiNamingEnabled = false
        off.startInbox(); await off.scan()
        let id3 = try #require(await off.finishInbox())
        #expect(off.latestDocument(id: id3).flatMap { $0.name(of: $0.groups[0]) } == "Tierarztpraxis Dr. Meier", "KI ausgeschaltet")
        await off.disconnect()
    }

    @Test func aNameTheUserGaveIsNotReplacedBySuggestions() async throws {
        let (model, a, o) = await makeModel(); defer { clean(a, o) }
        model.startInbox(); await model.scan()
        let id = try #require(model.series?.id)
        var doc = try #require(model.latestDocument(id: id))
        doc.setName("Mein Name", of: doc.groups[0].id)
        model.commit(doc)
        await model.finishInbox()
        let after = try #require(model.latestDocument(id: id))
        #expect(after.name(of: after.groups[0]) == "Mein Name")
        await model.disconnect()
    }

    @Test func filingWritesOnePdfPerDocumentNamedYearMonthAndDescriptionWithOCR() async throws {
        let (model, a, o) = await makeModel(); defer { clean(a, o) }
        model.startInbox(); await model.scan(); await model.scan(); await model.scan()
        let id = try #require(await model.finishInbox())
        // Zwei Seiten zusammenfassen: das erste und das zweite Dokument.
        var doc = try #require(model.latestDocument(id: id))
        _ = doc.mergeWithPrevious(pageID: doc.pages[1].id)
        doc.setName("Stadtwerke", of: doc.groups[0].id)
        doc.setName("Tierarztpraxis", of: doc.groups[1].id)
        model.commit(doc)

        let urls = await model.fileInbox(documentID: id)
        #expect(urls.count == 2)
        let prefix = InboxNaming.prefix(for: Date())
        #expect(urls.map(\.lastPathComponent) == ["\(prefix) Stadtwerke.pdf", "\(prefix) Tierarztpraxis.pdf"])
        #expect(PDFDocument(url: urls[0])?.pageCount == 2 && PDFDocument(url: urls[1])?.pageCount == 1)
        let text = PDFDocument(url: urls[1])?.string ?? ""
        #expect(text.contains("Tierarztpraxis"), "Mit Texterkennung durchsuchbar: \(text)")
        #expect(model.filedURLs == urls)
        #expect(model.savedDocuments.first { $0.id == id } == nil, "Die Schnellablage ist erledigt")
        #expect(!model.isInboxActive && model.exportProgress == nil)
        #expect(((try? ArchiveStore(root: a).allRecords()) ?? []).count == 3, "Die Originale bleiben im Archiv")
        await model.disconnect()
    }

    @Test func filingNeverOverwritesAnExistingPdf() async throws {
        let (model, a, o) = await makeModel(); defer { clean(a, o) }
        try FileManager.default.createDirectory(at: o, withIntermediateDirectories: true)
        let name = "\(InboxNaming.prefix(for: Date())) Stadtwerke.pdf"
        try Data("alt".utf8).write(to: o.appendingPathComponent(name))
        model.startInbox(); await model.scan()
        let id = try #require(await model.finishInbox())
        var doc = try #require(model.latestDocument(id: id))
        doc.setName("Stadtwerke", of: doc.groups[0].id); model.commit(doc)
        let urls = await model.fileInbox(documentID: id)
        #expect(urls.first?.lastPathComponent == "\(InboxNaming.prefix(for: Date())) Stadtwerke 2.pdf")
        #expect(try Data(contentsOf: o.appendingPathComponent(name)) == Data("alt".utf8), "Das alte PDF bleibt")
        await model.disconnect()
    }

    @Test func withoutAFolderNothingIsFiledAndTheInboxStays() async throws {
        let (model, a, o) = await makeModel(directory: false); defer { clean(a, o) }
        model.startInbox(); await model.scan()
        let id = try #require(await model.finishInbox())
        let urls = await model.fileInbox(documentID: id)
        #expect(urls.isEmpty)
        #expect(model.latestDocument(id: id) != nil, "Die Schnellablage bleibt zum erneuten Versuch")
        #expect(model.log.first?.level == .error)
        await model.disconnect()
    }

    @Test func theFileStemUsesTheMonthOfTheScanAndDokumentWithoutAName() async throws {
        let (model, a, o) = await makeModel(lines: []); defer { clean(a, o) }
        model.startInbox(); await model.scan()
        let id = try #require(await model.finishInbox())
        let doc = try #require(model.latestDocument(id: id))
        #expect(model.inboxFileStem(documentID: id, group: doc.groups[0]) == "\(InboxNaming.prefix(for: Date())) Dokument")
        await model.disconnect()
    }

    @Test func theSettingsAreRememberedAndHaveSensibleDefaults() {
        let suite = UserDefaults(suiteName: "scanutil-test-\(UUID().uuidString)")!
        let first = AppModel(scanner: MockScanner(previewsEnabled: false), store: ArchiveStore(root: FileManager.default.temporaryDirectory), defaults: suite)
        #expect(first.inboxDirectory == nil && first.triggerKeyCode == 49 && first.aiNamingEnabled)
        first.inboxDirectory = URL(fileURLWithPath: "/tmp/ablage", isDirectory: true)
        first.triggerKeyCode = 36
        first.aiNamingEnabled = false
        let second = AppModel(scanner: MockScanner(previewsEnabled: false), store: ArchiveStore(root: FileManager.default.temporaryDirectory), defaults: suite)
        #expect(second.inboxDirectory?.path == "/tmp/ablage" && second.triggerKeyCode == 36 && !second.aiNamingEnabled)
    }

    @Test func mergingSplittingAndRenamingGoThroughTheModelAndAreSaved() async throws {
        let (model, a, o) = await makeModel(lines: []); defer { clean(a, o) }
        model.startInbox(); await model.scan(); await model.scan(); await model.scan()
        let id = try #require(await model.finishInbox())
        let ids = try #require(model.latestDocument(id: id)).pages.map(\.id)
        model.mergeInboxPage(documentID: id, pageID: ids[1])
        model.mergeInboxPage(documentID: id, pageID: ids[2])
        #expect(model.latestDocument(id: id)?.groups.count == 1)
        model.splitInboxPage(documentID: id, pageID: ids[2])
        #expect(model.latestDocument(id: id)?.groups.map(\.pageIDs) == [[ids[0], ids[1]], [ids[2]]])
        let group = try #require(model.latestDocument(id: id)?.groups[1])
        model.renameInboxGroup(documentID: id, groupID: group.id, to: " Stadtwerke: Abrechnung ")
        let saved = try ArchiveStore(root: a).loadDocument(id: id)
        #expect(saved.groups.count == 2 && saved.name(of: saved.groups[1]) == "Stadtwerke Abrechnung", "Auch auf der Platte, bereinigt")
        // Die erste Seite lässt sich nicht abtrennen, ein unbekanntes Dokument nicht ändern.
        model.splitInboxPage(documentID: id, pageID: ids[0])
        model.mergeInboxPage(documentID: UUID(), pageID: ids[1])
        #expect(model.latestDocument(id: id)?.groups.count == 2)
        await model.disconnect()
    }

    @Test func discardingAnInboxKeepsTheScansAndOffersNoUndo() async throws {
        let (model, a, o) = await makeModel(); defer { clean(a, o) }
        model.startInbox(); await model.scan()
        let id = try #require(await model.finishInbox())
        #expect(model.openInboxes.map(\.id) == [id] && model.seriesDocuments.isEmpty, "Eine Schnellablage ist keine Serie")
        await model.discardInbox(documentID: id)
        #expect(model.openInboxes.isEmpty && model.undoableDeletion == nil)
        #expect(((try? ArchiveStore(root: a).allRecords()) ?? []).count == 1)
        // Eine Serie lässt sich auf diesem Weg nicht verwerfen.
        model.startSeries(title: "Serie"); await model.scan(); let sid = try #require(model.series?.id); model.endSeries()
        await model.discardInbox(documentID: sid)
        #expect(model.seriesDocuments.count == 1)
        await model.disconnect()
    }

    // MARK: Ganzer Dateiname

    @Test func theWholeFileNameIncludingYearAndMonthCanBeChanged() async throws {
        let (model, a, o) = await makeModel(); defer { clean(a, o) }
        model.startInbox(); await model.scan()
        let id = try #require(await model.finishInbox())
        let group = try #require(model.latestDocument(id: id)?.groups.first)
        let automatic = "\(InboxNaming.prefix(for: Date())) Tierarztpraxis Dr. Meier"
        #expect(model.inboxFileStem(documentID: id, group: group) == automatic)

        model.renameInboxFile(documentID: id, groupID: group.id, to: "2609 Gehalt Silvia")
        #expect(model.inboxFileStem(documentID: id, group: group) == "2609 Gehalt Silvia", "Auch Jahr und Monat sind änderbar")
        let saved = try ArchiveStore(root: a).loadDocument(id: id)
        #expect(saved.fileName(of: saved.groups[0]) == "2609 Gehalt Silvia", "Und auf der Platte")
        let urls = await model.fileInbox(documentID: id)
        #expect(urls.first?.lastPathComponent == "2609 Gehalt Silvia.pdf")
        await model.disconnect()
    }

    @Test func theFileNameIsCleanedAndAPdfEndingIsDropped() async throws {
        let (model, a, o) = await makeModel(); defer { clean(a, o) }
        model.startInbox(); await model.scan()
        let id = try #require(await model.finishInbox())
        let group = try #require(model.latestDocument(id: id)?.groups.first)
        model.renameInboxFile(documentID: id, groupID: group.id, to: "  2611 Rechnung: Tierarzt / Dr. Meier.PDF ")
        #expect(model.inboxFileStem(documentID: id, group: group) == "2611 Rechnung Tierarzt Dr. Meier")
        await model.disconnect()
    }

    @Test func clearingTheNameOrTypingTheAutomaticOneGoesBackToTheAutomaticName() async throws {
        let (model, a, o) = await makeModel(); defer { clean(a, o) }
        model.startInbox(); await model.scan()
        let id = try #require(await model.finishInbox())
        let group = try #require(model.latestDocument(id: id)?.groups.first)
        let automatic = model.inboxFileStem(documentID: id, group: group)
        model.renameInboxFile(documentID: id, groupID: group.id, to: "2609 Eigener Name")
        model.renameInboxFile(documentID: id, groupID: group.id, to: "   ")
        #expect(model.inboxFileStem(documentID: id, group: group) == automatic, "Leer nimmt den eigenen Namen zurück")
        model.renameInboxFile(documentID: id, groupID: group.id, to: "2609 Eigener Name")
        model.renameInboxFile(documentID: id, groupID: group.id, to: automatic)
        #expect(model.latestDocument(id: id)?.fileName(of: group) == nil, "Der gleiche Name ist kein eigener")
        // Danach folgt der Name wieder der Beschreibung.
        model.renameInboxGroup(documentID: id, groupID: group.id, to: "Stadtwerke")
        #expect(model.inboxFileStem(documentID: id, group: group) == "\(InboxNaming.prefix(for: Date())) Stadtwerke")
        await model.disconnect()
    }

    @Test func anOwnNameBeatsLaterSuggestionsAndMergingKeepsTheFrontOne() async throws {
        let (model, a, o) = await makeModel(); defer { clean(a, o) }
        model.startInbox(); await model.scan(); await model.scan()
        let id = try #require(model.series?.id)
        let first = try #require(model.latestDocument(id: id)?.groups[0]), second = try #require(model.latestDocument(id: id)?.groups[1])
        model.renameInboxFile(documentID: id, groupID: first.id, to: "2609 Vorne")
        model.renameInboxFile(documentID: id, groupID: second.id, to: "2609 Hinten")
        _ = await model.finishInbox()          // schlägt Beschreibungen vor, ändert aber die eigenen Namen nicht
        #expect(model.inboxFileStem(documentID: id, group: first) == "2609 Vorne")
        model.mergeInboxPage(documentID: id, pageID: try #require(model.latestDocument(id: id)?.pages[1].id))
        let merged = try #require(model.latestDocument(id: id)?.groups.first)
        #expect(model.latestDocument(id: id)?.groups.count == 1 && model.inboxFileStem(documentID: id, group: merged) == "2609 Vorne")
        #expect(model.latestDocument(id: id)?.inbox?.fileNames.count == 1, "Der eigene Name des hinteren fällt weg")
        await model.disconnect()
    }
}
