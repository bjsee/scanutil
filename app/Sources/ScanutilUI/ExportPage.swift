import AppKit
import ArchiveKit
import ExportKit
import SwiftUI

/// Wohin ein PDF geschrieben wird: Ordner, Dateiname, und nie über eine vorhandene Datei.
public enum ExportTarget {
    /// Der Standardordner: `Dokumente/Chronik-Scanner`. Für die Oberflächentests ersetzt `SCANUTIL_EXPORT_DIR` ihn.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["SCANUTIL_EXPORT_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return documents.appendingPathComponent("Chronik-Scanner", isDirectory: true)
    }

    /// Ein brauchbarer Dateiname aus dem Titel: ohne Pfadtrenner und Doppelpunkt, nie leer, mit Endung `.pdf` (genau einmal).
    public static func fileName(for title: String) -> String {
        var name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)).trimmingCharacters(in: .whitespaces) }
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Serie" }
        return name + ".pdf"
    }

    /// Der Zielpfad im Ordner. Gibt es die Datei schon, wird `name 2.pdf`, `name 3.pdf` … gewählt: Ein früheres PDF geht nicht verloren.
    public static func url(directory: URL, title: String, fileManager: FileManager = .default) -> URL {
        let file = fileName(for: title)
        let stem = String(file.dropLast(4))
        var candidate = directory.appendingPathComponent(file)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(n).pdf")
            n += 1
        }
        return candidate
    }
}

/// Die Seite „PDF ausgeben“: Name, Ordner und Optionen, dann erzeugen. Kein Speicherdialog; der Ordner lässt sich ändern.
struct ExportPage: View {
    @Bindable var model: AppModel
    let documentID: UUID
    let nav: Navigator

    @State private var name: String?
    @State private var directory = ExportTarget.defaultDirectory()
    @State private var withOCR = false
    @State private var small = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let document = model.latestDocument(id: documentID) {
                form(document).padding(24)
            } else {
                Text("Diese Serie gibt es nicht mehr.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("export-page")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { nav.back(fallback: .series) } label: { Label("Zurück", systemImage: "chevron.left") }
                .buttonStyle(.link).accessibilityIdentifier("export-back")
            Text("›").foregroundStyle(.secondary)
            Text(model.latestDocument(id: documentID)?.title ?? "Serie").font(.title3.bold())
            Text("› PDF ausgeben").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20).frame(height: 56)
    }

    private func form(_ document: ScanDocument) -> some View {
        let open = model.review(of: document).needingAttention.count
        let busy = model.exportProgress != nil
        let fileName = Binding(get: { name ?? ExportTarget.fileName(for: document.title) }, set: { name = $0 })
        return VStack(alignment: .leading, spacing: 16) {
            if open > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(open) Seite\(open == 1 ? " ist" : "n sind") noch unsicher.")
                    Button("Jetzt prüfen") { nav.go(.editor(document.id)) }.buttonStyle(.link)
                        .accessibilityIdentifier("export-review-link")
                    Spacer()
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
                .accessibilityIdentifier("export-unsure-note")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Dateiname").font(.caption).foregroundStyle(.secondary)
                TextField("Dateiname", text: fileName).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                    .accessibilityIdentifier("export-name-field")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Ordner").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(directory.path).lineLimit(1).truncationMode(.middle)
                        .padding(8).frame(maxWidth: 420, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
                        .accessibilityIdentifier("export-directory")
                    Button("Ändern …") { chooseDirectory() }.accessibilityIdentifier("export-directory-button")
                }
            }
            Toggle("Mit Texterkennung (durchsuchbar, etwa 1,5 s je Seite)", isOn: $withOCR)
                .toggleStyle(.switch).accessibilityIdentifier("export-ocr-toggle")
            Toggle("Kleine Datei (längste Kante 2000 px)", isOn: $small)
                .toggleStyle(.switch).accessibilityIdentifier("export-small-toggle")

            if let progress = model.exportProgress {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Seite \(progress.done) von \(progress.total)").font(.callout)
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(maxWidth: 420)
                }
                .accessibilityIdentifier("export-progress")
            }
            HStack(spacing: 12) {
                Button("PDF erzeugen") { run(document) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || document.pages.isEmpty)
                    .accessibilityIdentifier("export-run-button")
                if let url = model.lastExportURL, !busy {
                    Button("PDF zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link).accessibilityIdentifier("export-reveal-button")
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }
            if document.pages.isEmpty { Text("Die Serie hat noch keine Seiten.").foregroundStyle(.secondary) }
        }
    }

    private func run(_ document: ScanDocument) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var title = name ?? document.title
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = document.title }
        let url = ExportTarget.url(directory: directory, title: title)
        var options = small ? ExportOptions.web : ExportOptions.archive
        options.ocr = withOCR
        // Fotos behalten mehr Qualität (JPEG 95 statt 85 %); „Kleine Datei“ bleibt klein.
        if !small { options.jpegQuality = max(options.jpegQuality, document.effectiveProfile.jpegQuality) }
        Task { await model.exportDocument(document, to: url, options: options) }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.prompt = "Wählen"
        if panel.runModal() == .OK, let url = panel.url { directory = url }
    }
}
