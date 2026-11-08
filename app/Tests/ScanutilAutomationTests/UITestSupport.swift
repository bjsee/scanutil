import Foundation

/// Gemeinsame Hilfen der Oberflächentests: App starten, Dateien im Archiv lesen.
struct UISession {
    let app: AppDriver
    let dir: URL
    /// Ordner, in dem der Speicherdialog des Exports öffnet.
    let exportDir: URL
    /// Die Zielordner der Schnellablage: „Privat“ (zuerst, gewählt) und „Verein“.
    let inboxDir: URL
    let inboxDir2: URL

    func close() {
        try? FileManager.default.removeItem(at: inboxDir)
        try? FileManager.default.removeItem(at: inboxDir2)
        app.terminate()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: exportDir)
    }

    private func files(_ folder: String, ext: String, in base: URL? = nil) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: (base ?? dir).appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == ext }
    }

    var originals: [URL] { files("originals", ext: "png") }
    var correctionFiles: [URL] { files("corrections", ext: "json") }

    /// Die gespeicherten Korrekturen des ersten Scans als JSON, oder `nil`.
    var corrections: [String: Any]? {
        guard let file = correctionFiles.first, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    var documentFiles: [URL] { files("documents", ext: "json") }
    var pdfs: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "pdf" }
    }

    /// Die PDFs, die die Schnellablage im ersten Ziel (Privat) abgelegt hat, nach Namen sortiert.
    var inboxPDFs: [URL] { pdfs(in: inboxDir) }
    /// Die PDFs im zweiten Ziel (Verein).
    var inboxPDFs2: [URL] { pdfs(in: inboxDir2) }

    private func pdfs(in directory: URL) -> [URL] {
        (((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "pdf" })
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Das gespeicherte Dokument der Serie als JSON, oder `nil`.
    var document: [String: Any]? {
        guard let file = documentFiles.first, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Die Titel aller gespeicherten Dokumente.
    var documentTitles: [String] {
        documentFiles.compactMap { file in
            (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["title"] as? String
        }
    }

    var pages: [[String: Any]] { (document?["pages"] as? [[String: Any]]) ?? [] }

    /// Der Drehwinkel und die Herkunft der Seite `index` im gespeicherten Dokument.
    func rotation(ofPage index: Int) -> (degrees: Double, source: String)? {
        guard pages.indices.contains(index),
              let corrections = pages[index]["corrections"] as? [String: Any],
              let rotation = corrections["rotation"] as? [String: Any],
              let degrees = rotation["degrees"] as? Double, let source = rotation["source"] as? String else { return nil }
        return (degrees, source)
    }

    /// Ob die Seite `index` im gespeicherten Dokument schon einen Zuschnitt trägt. Den setzt erst die Analyse:
    /// ohne sie steht dort nichts. So lässt sich auf das Ende der Automatik warten.
    func hasCrop(ofPage index: Int) -> Bool {
        guard pages.indices.contains(index), let corrections = pages[index]["corrections"] as? [String: Any],
              let crop = corrections["crop"] as? [String: Any] else { return false }
        return crop["quad"] != nil
    }

    static func launch(mode: String = "document") throws -> UISession {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("scanutil-ui-\(UUID().uuidString)")
        let exportDir = base.appendingPathComponent("scanutil-ui-export-\(UUID().uuidString)")
        let inboxDir = base.appendingPathComponent("scanutil-ui-inbox-\(UUID().uuidString)")
        let inboxDir2 = base.appendingPathComponent("scanutil-ui-inbox2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let app = try AppDriver(mode: mode, archive: dir, environment: ["SCANUTIL_EXPORT_DIR": exportDir.path, "SCANUTIL_INBOX_DIRS": "Privat=\(inboxDir.path)|Verein=\(inboxDir2.path)"])
        return UISession(app: app, dir: dir, exportDir: exportDir, inboxDir: inboxDir, inboxDir2: inboxDir2)
    }
}

/// Die Schrittweite der Zoomknöpfe, wie in der App (`ZoomState.buttonStep`). Hier doppelt, weil die Oberflächentests die App nur von außen sehen.
enum ZoomState { static let buttonStepForTests = 1.5 }
