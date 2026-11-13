import ArchiveKit
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

@Suite("Profile: Eigenschaften")
struct ScanProfileBasicsTests {
    @Test func threeProfilesWithTheirTraits() {
        #expect(ScanProfile.allCases == [.book, .document, .photo])
        #expect(ScanProfile.book.isBook && !ScanProfile.document.isBook && !ScanProfile.photo.isBook)
        #expect(ScanProfile.book.lightensPaper && ScanProfile.document.lightensPaper && !ScanProfile.photo.lightensPaper)
        #expect(ScanProfile.photo.jpegQuality > ScanProfile.document.jpegQuality)
        #expect(ScanProfile.allCases.map(\.title) == ["Buch", "Dokument", "Foto"])
        #expect(ScanProfile.allCases.allSatisfy { !$0.summary.isEmpty })
    }

    @Test func aPhotoProfileSwitchesTheAutomaticLighteningOffAndKeepsManualChoices() {
        var automatic = Corrections()
        automatic.tone = ToneCorrection(enabled: true, source: .automatic)
        #expect(ScanProfile.photo.adjusted(automatic).tone.enabled == false)
        #expect(ScanProfile.document.adjusted(automatic).tone.enabled)
        var off = Corrections()
        off.tone = ToneCorrection(enabled: false, source: .automatic)
        #expect(ScanProfile.book.adjusted(off).tone.enabled, "Ein Buch hellt auf, auch wenn die Vorlage es noch nicht eingeschaltet hatte")
        var manual = Corrections()
        manual.setToneEnabled(true)                       // Handeingabe: bleibt, auch im Fotoprofil
        #expect(ScanProfile.photo.adjusted(manual).tone.enabled)
        var manualOff = Corrections()
        manualOff.setToneEnabled(false)
        #expect(!ScanProfile.document.adjusted(manualOff).tone.enabled)
    }

    @Test func theDocumentKnowsItsProfileOrInfersIt() throws {
        var doc = ScanDocument(title: "A")
        #expect(doc.effectiveProfile == .document, "Ohne Seiten und ohne Profil: Dokument")
        doc.append(DocumentPage(scanID: UUID(), region: .left))
        #expect(doc.effectiveProfile == .book, "Doppelseiten sind ein Buch")
        doc.profile = .photo
        #expect(doc.effectiveProfile == .photo, "Ein gesetztes Profil gilt")
        let back = try JSONDecoder().decode(ScanDocument.self, from: JSONEncoder().encode(doc))
        #expect(back.profile == .photo)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ScanDocument(title: "Alt"))) as? [String: Any])
        object["profile"] = nil
        #expect(try JSONDecoder().decode(ScanDocument.self, from: JSONSerialization.data(withJSONObject: object)).profile == nil, "Ältere Dateien kennen es nicht")
    }
}

@MainActor
@Suite("Profile: Serie")
struct ScanProfileModelTests {
    private func makeModel() async -> (AppModel, ArchiveStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-profile-\(UUID().uuidString)")
        let store = ArchiveStore(root: dir)
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: store, thumbnailSize: 128, sound: SilentSound(), defaults: nil)
        await model.connect()
        return (model, store, dir)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(30)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(25)) }
        return condition()
    }

    @Test func aSeriesRemembersItsProfileAndOnlyTheBookIsASpreadSeries() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Fotos", profile: .photo)
        #expect(model.series?.profile == .photo && !model.seriesIsBook)
        await model.scan()
        #expect(model.series?.pages.count == 1, "Ein Foto ist eine Seite")
        #expect(try store.loadDocument(id: #require(model.series?.id)).profile == .photo, "Das Profil steht im Dokument")
        model.endSeries()
        model.startSeries(title: "Buch", profile: .book)
        #expect(model.series?.profile == .book && model.seriesIsBook)
        model.endSeries()
        model.startSeries(title: "Alt", book: true)
        #expect(model.series?.profile == .book, "Der alte Parameter `book` ergibt Buch")
        model.endSeries()
        model.startSeries(title: "Ablage", inbox: true, profile: .photo)
        #expect(model.series?.profile == .document, "Die Schnellablage nimmt Dokument")
        await model.disconnect()
    }

    @Test func aPhotoSeriesDoesNotLightenButADocumentSeriesDoes() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Foto", profile: .photo)
        await model.scan()
        #expect(await eventually { model.analyzing.isEmpty && model.series?.pages.first?.analysis != nil })
        #expect(model.series?.pages.first?.corrections.tone.enabled == false, "Fotoprofil: nicht aufhellen")
        #expect(model.scans.first?.corrections.tone.enabled == false)
        model.endSeries()

        model.startSeries(title: "Brief", profile: .document)
        await model.scan()
        #expect(await eventually { model.analyzing.isEmpty && model.series?.pages.first?.analysis != nil })
        #expect(model.series?.pages.first?.corrections.tone.enabled == true, "Dokumentprofil: aufhellen")
        await model.disconnect()
    }

    @Test func switchingTheProfileOfASeriesFollowsAutomaticPagesAndKeepsManualOnes() async throws {
        let (model, store, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Mix", profile: .document)
        await model.scan(); await model.scan()
        let id = try #require(model.series?.id)
        #expect(await eventually { model.analyzing.isEmpty && model.series?.pages.allSatisfy { $0.analysis != nil } == true })
        let ids = try #require(model.series?.pages.map(\.id))
        model.updatePage(documentID: id, pageID: ids[1]) { $0.setToneEnabled(true) }        // Handeingabe
        #expect(model.setProfile(.photo, documentID: id))
        let doc = try #require(model.latestDocument(id: id))
        #expect(doc.profile == .photo)
        #expect(doc.pages[0].corrections.tone.enabled == false, "Automatische Seite folgt dem Profil")
        #expect(doc.pages[1].corrections.tone.enabled == true, "Von Hand eingeschaltet bleibt")
        #expect(try store.loadDocument(id: id).profile == .photo)
        #expect(model.setProfile(.document, documentID: id))
        #expect(model.latestDocument(id: id)?.pages.allSatisfy { $0.corrections.tone.enabled } == true)
        await model.disconnect()
    }

    @Test func aSeriesCannotBecomeABookNorABookAPlainSeries() async throws {
        let (model, _, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Einzeln", profile: .document); await model.scan()
        let single = try #require(model.series?.id)
        model.endSeries()
        #expect(!model.setProfile(.book, documentID: single), "Einzelseiten lassen sich nicht in ein Buch verwandeln")
        #expect(model.latestDocument(id: single)?.profile == .document)
        #expect(model.log.first?.level == .warning)
        model.startSeries(title: "Buch", profile: .book); await model.scan()
        let book = try #require(model.series?.id)
        model.endSeries()
        #expect(!model.setProfile(.photo, documentID: book), "Doppelseiten bleiben ein Buch")
        #expect(model.setProfile(.book, documentID: book))
        #expect(!model.setProfile(.photo, documentID: UUID()))
        // Ein noch leeres Dokument darf noch wechseln.
        model.startSeries(title: "Leer", profile: .document)
        let empty = try #require(model.series?.id)
        model.endSeries()
        #expect(model.setProfile(.photo, documentID: empty))
        await model.disconnect()
    }
}
