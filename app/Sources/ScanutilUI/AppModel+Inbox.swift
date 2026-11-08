import ArchiveKit
import CoreGraphics
import ExportKit
import Foundation
import ImagingKit

/// Die Schnellablage: lose Dokumente aufnehmen, benennen, zusammenfassen und als PDF mit Texterkennung ablegen.
extension AppModel {
    /// Beginnt eine Schnellablage. Jede Aufnahme (Fußtaster, Taste, Schaltfläche) ist zunächst ein Dokument für sich.
    public func startInbox() {
        startSeries(title: "", book: false, inbox: true)
    }

    /// Beendet die Aufnahme („Fertig“) und schlägt für jedes Dokument einen Namen vor.
    /// - Returns: die Kennung des Dokuments der Schnellablage zum Bearbeiten, `nil` wenn keine läuft.
    @discardableResult
    public func finishInbox() async -> UUID? {
        guard let id = series?.id, isInboxActive else { return nil }
        endSeries()
        await suggestNames(documentID: id)
        return id
    }

    /// Schlägt für jedes noch unbenannte Dokument der Schnellablage eine Beschreibung vor: mit der KI auf dem Mac, wenn sie
    /// eingeschaltet und verfügbar ist, sonst nach einer einfachen Regel aus dem erkannten Text. Ein vom Nutzer vergebener
    /// Name bleibt unberührt.
    public func suggestNames(documentID: UUID) async {
        guard let initial = latestDocument(id: documentID), initial.isInbox else { return }
        isSuggestingNames = true
        defer { isSuggestingNames = false }
        for group in initial.groups {
            guard let current = latestDocument(id: documentID), current.name(of: group) == nil,
                  let firstID = group.pageIDs.first, let page = current.page(id: firstID) else { continue }
            let lines = await recognizedLines(of: page)
            var suggestion: String?
            if aiNamingEnabled, describer.isAvailable, !lines.isEmpty { suggestion = await describer.describe(text: lines.joined(separator: "\n")) }
            if suggestion.map({ InboxNaming.cleanedDescription($0).isEmpty }) ?? true { suggestion = InboxNaming.heuristicDescription(from: lines) }
            guard let suggestion, !InboxNaming.cleanedDescription(suggestion).isEmpty else { continue }
            // Zwischenzeitlich vom Nutzer benannt? Dann gilt sein Name.
            guard var latest = latestDocument(id: documentID), latest.name(of: group) == nil else { continue }
            latest.setName(InboxNaming.cleanedDescription(suggestion), of: group.id)
            commit(latest)
        }
    }

    /// Die Schnellablagen, die noch nicht abgelegt sind (nach einem Neustart oder „Fertig“), neueste zuerst.
    public var openInboxes: [ScanDocument] { savedDocuments.filter(\.isInbox) }

    /// Die Serien ohne die Schnellablagen: für die Liste der Serien.
    public var seriesDocuments: [ScanDocument] { savedDocuments.filter { !$0.isInbox } }

    /// Ob die KI für Namensvorschläge auf diesem Mac bereitsteht.
    public var aiNamingAvailable: Bool { describer.isAvailable }

    /// Ändert den Namen eines Dokuments der Schnellablage.
    public func renameInboxGroup(documentID: UUID, groupID: UUID, to name: String) {
        guard var document = latestDocument(id: documentID), document.isInbox else { return }
        let cleaned = InboxNaming.cleanedDescription(name)
        guard document.inbox?.names[groupID.uuidString] != (cleaned.isEmpty ? nil : cleaned) else { return }
        document.setName(cleaned, of: groupID)
        commit(document)
    }

    /// Fasst das Dokument der Seite mit dem davor zusammen.
    public func mergeInboxPage(documentID: UUID, pageID: UUID) {
        guard var document = latestDocument(id: documentID), document.isInbox, document.mergeWithPrevious(pageID: pageID) else { return }
        commit(document)
    }

    /// Trennt das Dokument vor der Seite auf.
    public func splitInboxPage(documentID: UUID, pageID: UUID) {
        guard var document = latestDocument(id: documentID), document.isInbox, document.splitBefore(pageID: pageID) else { return }
        commit(document)
    }

    /// Verwirft eine Schnellablage, ohne etwas abzulegen. Die Originale bleiben im Archiv.
    public func discardInbox(documentID: UUID) async {
        guard latestDocument(id: documentID)?.isInbox == true else { return }
        await deleteDocument(id: documentID)
        undoableDeletion = nil
    }

    /// Der erkannte Text der Seite, Zeilen von oben nach unten, so wie sie später im PDF stünde (mit den Korrekturen).
    func recognizedLines(of page: DocumentPage) async -> [String] {
        let store = self.store, recognizer = self.recognizer
        let corrections = PageGeometry.effectiveCorrections(for: page), scanID = page.scanID
        return await Task.detached { () -> [String] in
            guard let record = try? store.load(id: scanID), let thumb = store.thumbnail(for: record, maxPixelSize: 2000),
                  let image = CorrectionRenderer.render(thumb, corrections: corrections),
                  let lines = try? recognizer.recognize(image, languages: ["de-DE", "en-US"]) else { return [] }
            return lines.sorted { $0.box.maxY > $1.box.maxY }.map(\.text)
        }.value
    }

    /// Das Ziel eines Dokuments: das eigene, wenn es noch in der Liste steht, sonst das gerade gewählte. `nil` ohne Ziele.
    public func inboxTarget(for group: PageGroup, in document: ScanDocument) -> InboxTarget? {
        document.target(of: group).flatMap { inboxTargets.target(id: $0) } ?? inboxTargets.active
    }

    /// Ändert das Ziel eines Dokuments der Schnellablage.
    public func setInboxGroupTarget(documentID: UUID, groupID: UUID, targetID: UUID) {
        guard var document = latestDocument(id: documentID), document.isInbox, inboxTargets.target(id: targetID) != nil else { return }
        guard document.inbox?.targets[groupID.uuidString] != targetID.uuidString else { return }
        document.setTarget(targetID, of: groupID)
        commit(document)
    }

    /// Der Dateiname (ohne Endung), unter dem das Dokument abgelegt würde: ein vom Nutzer vorgegebener ganz, sonst Jahr und Monat der
    /// Aufnahme, dann die Beschreibung.
    public func inboxFileStem(documentID: UUID, group: PageGroup) -> String {
        guard let document = latestDocument(id: documentID) else { return InboxNaming.fileStem(date: Date(), description: nil) }
        return document.fileName(of: group) ?? automaticFileStem(of: group, in: document)
    }

    /// Der Name aus Jahr und Monat der Aufnahme und der Beschreibung, ohne Rücksicht auf einen vorgegebenen.
    private func automaticFileStem(of group: PageGroup, in document: ScanDocument) -> String {
        let date = group.pageIDs.first.flatMap { document.page(id: $0)?.scanID }.flatMap { try? store.load(id: $0).capture.capturedAt } ?? Date()
        return InboxNaming.fileStem(date: date, description: document.name(of: group))
    }

    /// Ändert den ganzen Dateinamen eines Dokuments, auch Jahr und Monat. Eine Endung `.pdf` wird abgeschnitten, unzulässige Zeichen
    /// werden ersetzt. Ist das Ergebnis leer oder gleicht es dem Namen, der ohnehin entstünde, gilt wieder der selbst gebildete
    /// (er folgt dann späteren Änderungen der Beschreibung).
    public func renameInboxFile(documentID: UUID, groupID: UUID, to name: String) {
        guard let document = latestDocument(id: documentID), document.isInbox,
              let group = document.groups.first(where: { $0.id == groupID }) else { return }
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix(".pdf") { text = String(text.dropLast(4)) }
        let cleaned = InboxNaming.cleanedDescription(text)
        let newName: String? = (cleaned.isEmpty || cleaned == automaticFileStem(of: group, in: document)) ? nil : cleaned
        guard document.fileName(of: group) != newName else { return }
        var updated = document
        updated.setFileName(newName, of: groupID)
        commit(updated)
    }

    /// Legt alle Dokumente der Schnellablage als PDF mit Texterkennung im eingestellten Ordner ab. Ein vorhandenes PDF gleichen
    /// Namens wird nie überschrieben (`… 2.pdf`). Danach ist die Schnellablage erledigt: Sie verschwindet aus den Serien, die
    /// Originale bleiben im Archiv.
    /// - Returns: die geschriebenen PDFs; leer, wenn es nicht geklappt hat (der Grund steht im Protokoll).
    @discardableResult
    public func fileInbox(documentID: UUID) async -> [URL] {
        guard exportProgress == nil else { return [] }
        guard let document = latestDocument(id: documentID), document.isInbox else { return [] }
        // Jedes Dokument geht in sein Ziel, ersatzweise ins gewählte. Fehlt eines davon, wird vorher nichts geschrieben.
        let plan = document.groups.map { ($0, inboxTarget(for: $0, in: document)) }
        guard !plan.isEmpty, !plan.contains(where: { $0.1 == nil }) else {
            post(.error, "Es ist noch kein Zielordner für die Schnellablage eingestellt (Einstellungen), oder ein Dokument hat keinen.")
            return []
        }
        guard !document.pages.isEmpty else { post(.warning, "Die Schnellablage hat noch keine Seiten."); return [] }
        for case let (_, target?) in plan {
            do { try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true) } catch {
                post(.error, "Der Ordner „\(target.path)“ ist nicht beschreibbar: \(error.localizedDescription)")
                return []
            }
        }
        exportProgress = (0, document.pages.count)
        message = nil
        let exporter = PDFExporter(store: store, recognizer: recognizer)
        var options = ExportOptions.archive
        options.ocr = true
        var written: [URL] = []
        var done = 0
        let total = document.pages.count
        for (group, target) in plan {
            guard let directory = target?.url else { continue }
            let pages = group.pageIDs.compactMap { document.page(id: $0) }
            var part = ScanDocument(title: document.title, pages: pages)
            part.revision = 0
            let target = ExportTarget.url(directory: directory, title: inboxFileStem(documentID: documentID, group: group))
            let before = done
            do {
                let url = target, opts = options, exp = exporter, doc = part
                _ = try await Task.detached {
                    try exp.export(doc, to: url, options: opts) { finished, _ in
                        Task { @MainActor in self.exportProgress = (before + finished, total) }
                    }
                }.value
                written.append(target)
                done += pages.count
            } catch {
                post(.error, "„\(target.lastPathComponent)“ konnte nicht abgelegt werden: \(error.localizedDescription)")
                exportProgress = nil
                filedURLs = written
                return []
            }
        }
        exportProgress = nil
        filedURLs = written
        post(.info, "Schnellablage abgelegt: " + written.map(\.lastPathComponent).joined(separator: ", "))
        try? store.deleteDocument(id: documentID)
        savedDocuments.removeAll { $0.id == documentID }
        if openedDocument?.id == documentID { openedDocument = nil }
        return written
    }
}
