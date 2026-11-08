import ArchiveKit
import CoreGraphics
import ExportKit
import Foundation
import ImagingKit
import ScannerKit

/// Dateien statt eines Scans: Bilder und PDFs kommen wie Aufnahmen in die Schnellablage und bekommen Namen und Texterkennung
/// auf demselben Weg.
extension AppModel {
    /// Nimmt Dateien in die Schnellablage auf. Läuft gerade eine Schnellablage (Aufnahme), kommen sie ans Ende; sonst entsteht eine
    /// neue, die zum Prüfen und Ablegen bereitsteht. Eine Bilddatei ist ein Dokument; die Seiten einer PDF-Datei bilden zusammen
    /// eines. Jedes Dokument geht in das gerade gewählte Ziel. Für die Namen der Dokumente wird (außer bei laufender Aufnahme,
    /// wo es mit „Fertig“ geschieht) sofort der Text gelesen.
    /// - Returns: die Kennung der Schnellablage, oder `nil`, wenn nichts übernommen wurde.
    @discardableResult
    public func importFiles(_ urls: [URL]) async -> UUID? {
        let supported = urls.filter { !$0.hasDirectoryPath && FileImport.isSupported($0) }
        for url in urls where !supported.contains(url) {
            post(.warning, "„\(url.lastPathComponent)“ lässt sich nicht aufnehmen: Unterstützt werden Bilder und PDF-Dateien.")
        }
        guard !supported.isEmpty else { return nil }

        let running = isInboxActive
        let documentID: UUID
        if running, let id = series?.id { documentID = id }
        else {
            let document = ScanDocument(title: Self.defaultInboxTitle(), inbox: InboxInfo())
            do { try store.saveDocument(document) } catch {
                post(.error, "Die Schnellablage konnte nicht angelegt werden: \(error.localizedDescription)")
                return nil
            }
            updateSavedDocuments(with: document)
            documentID = document.id
        }

        isImporting = true
        defer { isImporting = false }
        var imported = 0
        for url in supported {
            let store = self.store
            let records: [ScanRecord] = await Task.detached { () -> [ScanRecord] in
                let images = FileImport.images(from: url)
                var result: [ScanRecord] = []
                for image in images {
                    guard let png = FileImport.pngData(image) else { continue }
                    let metadata = CaptureMetadata(device: DeviceInfo(name: "Import", identifier: "import"),
                                                   requestedFormat: ScanFormat(width: image.width, height: image.height),
                                                   capturedAt: Date(), sharpness: nil)
                    let capture = Capture(imageData: png, width: image.width, height: image.height, metadata: metadata)
                    if let record = try? store.store(capture) { result.append(record) }
                }
                return result
            }.value
            guard !records.isEmpty, var document = latestDocument(id: documentID) else {
                post(.error, "„\(url.lastPathComponent)“ konnte nicht gelesen werden.")
                continue
            }
            // Die Seiten einer Datei sind ein Dokument; es geht ins gerade gewählte Ziel.
            var groupID: UUID?
            for record in records {
                var page = DocumentPage(scanID: record.id, region: .whole, corrections: .none,
                                        analysis: PageAnalysis(outerDetected: true, outerPlausibility: 1), groupID: groupID)
                if groupID == nil { groupID = page.id } else { page.groupID = groupID }
                document.append(page)
                if page.id == groupID { document.setTarget(inboxTargets.activeID, of: page.id) }
            }
            commit(document)
            imported += 1
        }
        guard imported > 0 else { return nil }
        post(.info, "\(imported) Datei(en) in die Schnellablage übernommen.")
        if !running { await suggestNames(documentID: documentID) }
        return documentID
    }
}
