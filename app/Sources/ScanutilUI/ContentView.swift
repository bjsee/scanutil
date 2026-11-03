import AppKit
import ArchiveKit
import ExportKit
import ImagingKit
import ScannerKit
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @Bindable var model: AppModel
    @State private var keyMonitor = SpaceKeyMonitor()
    @State private var showLog = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                previewPane
                    .frame(minWidth: 480)
                scansPane
                    .frame(minWidth: 380, idealWidth: 480)
            }
            Divider()
            SeriesBar(model: model)
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 560)
        // Die Leertaste löst den Scan aus. Als Tastenkürzel der Schaltfläche kommt sie nicht an,
        // weil das Fokussystem eine Taste ohne Modifikator abfängt, deshalb ein Monitor auf AppKit-Ebene.
        .onAppear { keyMonitor.start { Task { await model.scan() } } }
        .onDisappear { keyMonitor.stop() }
        .task {
            await model.loadArchive()
            await model.connect()
        }
    }

    private var previewPane: some View {
        ZStack {
            Color.black
            if let image = model.previewImage {
                // Die Vorschau hat nur rund 1500 Pixel Breite: gezoomt wird, was sie hergibt. Die Aufnahme selbst ist schärfer.
                ZoomableImageView(image: image, identifier: "preview")
            } else if case .failed(let text) = model.status {
                VStack(spacing: 14) {
                    Label(text, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if model.isSearching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Die App sucht weiter und verbindet sich, sobald der Scanner da ist.")
                                .font(.callout).foregroundStyle(.white.opacity(0.8))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("search-status")
                    }
                    Button("Jetzt suchen") { Task { await model.connect() } }
                        .accessibilityIdentifier("reconnect-button")
                }
                .padding()
            } else {
                ProgressView().controlSize(.large)
            }
            if model.status == .capturing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Aufnahme läuft …").foregroundStyle(.white)
                }
                .padding(20)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var scansPane: some View {
        VStack(spacing: 0) {
            if let item = model.selectedItem {
                ScanDetailView(model: model, item: item)
            } else {
                Text("Noch kein Scan.\nLeertaste drückt den Auslöser.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(model.scans) { item in
                        ThumbnailCell(item: item, selected: item.id == model.selectedID, needsReview: item.corrections.needsReview)
                            .onTapGesture { model.selectedID = item.id }
                    }
                }
                .padding(8)
            }
            .frame(height: 96)
            .accessibilityLabel("Letzte Scans")
            .accessibilityValue("\(model.scans.count)")
            .accessibilityIdentifier("thumbnail-strip")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.scan() }
            } label: {
                Label("Scannen", systemImage: "camera.shutter.button")
            }
            .disabled(model.status != .ready)
            .help("Leertaste")
            .accessibilityIdentifier("scan-button")

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText).font(.callout).accessibilityIdentifier("status-text")
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                } else if let format = model.captureFormat {
                    Text("Aufnahme \(format.description), Schärfe 0 (Archivmodus)" + durationText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                showLog.toggle()
                if showLog { model.markLogSeen() }
            } label: {
                Label("Meldungen", systemImage: model.unseenIssues > 0 ? "exclamationmark.bubble.fill" : "text.bubble")
                    .foregroundStyle(model.unseenIssues > 0 ? Color.orange : Color.primary)
                    .overlay(alignment: .topTrailing) {
                        if model.unseenIssues > 0 {
                            Text("\(min(model.unseenIssues, 99))")
                                .font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 4).background(Capsule().fill(.red))
                                .offset(x: 10, y: -8)
                        }
                    }
            }
            .help("Warnungen und Hinweise dieser Sitzung")
            .accessibilityLabel("Meldungen")
            .accessibilityValue("\(model.unseenIssues) neu, \(model.log.count) insgesamt")
            .accessibilityIdentifier("log-button")
            .popover(isPresented: $showLog, arrowEdge: .top) { LogView(model: model) }
            Button("Archiv im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting([model.archiveURL])
            }
            .buttonStyle(.link)
        }
        .padding(10)
    }

    private var durationText: String {
        guard let d = model.lastScanDuration else { return "" }
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: " · letzter Scan %.1f s", seconds)
    }

    private var statusText: String {
        switch model.status {
        case .disconnected: "Nicht verbunden"
        case .connecting: "Verbinde …"
        case .ready: model.device.map { "Bereit: \($0.name)" } ?? "Bereit"
        case .capturing: "Aufnahme läuft"
        case .failed: model.isSearching ? "Suche Scanner …" : "Nicht verfügbar"
        }
    }
}

/// Protokoll der Sitzung: Warnungen der Analyse, übersprungene Dubletten, Fehler des Scanners, Berichte vom Export.
struct LogView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Meldungen").font(.headline)
                Text("\(model.log.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                }
                .disabled(model.log.isEmpty)
                .accessibilityIdentifier("log-copy-button")
                Button("Leeren") { model.clearLog() }
                    .disabled(model.log.isEmpty)
                    .accessibilityIdentifier("log-clear-button")
            }
            .padding(10)
            Divider()
            if model.log.isEmpty {
                Text("Keine Meldungen.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView { LogList(model: model) }
                    .accessibilityLabel("Meldungen")
                    .accessibilityIdentifier("log-list")
            }
        }
        .frame(width: 520, height: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("log-view")
    }
}

/// Die Zeilen des Protokolls, neueste zuerst. Ohne Rahmen zum Scrollen, damit sie sich einzeln darstellen lassen.
struct LogList: View {
    @Bindable var model: AppModel

    var body: some View {
        // Bewusst kein LazyVStack: höchstens `AppModel.logLimit` kurze Zeilen, und ein fauler Stapel baut
        // unter ImageRenderer keine Zeilen, die Darstellung ließe sich dann nicht prüfen.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.log) { entry in
                LogRow(entry: entry, scanLabel: scanLabel(for: entry)) {
                    if let id = entry.scanID, model.scans.contains(where: { $0.id == id }) { model.selectedID = id }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
            }
        }
    }

    /// „Scan 14:32:05“ für Einträge zu einem Scan, damit man sieht, welcher gemeint ist.
    private func scanLabel(for entry: LogEntry) -> String? {
        guard let id = entry.scanID else { return nil }
        guard let item = model.scans.first(where: { $0.id == id }) else { return "Scan" }
        return "Scan " + item.record.capture.capturedAt.formatted(.dateTime.hour().minute().second())
    }
}

struct LogRow: View {
    let entry: LogEntry
    let scanLabel: String?
    let select: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(entry.time.formatted(.dateTime.hour().minute().second()))
                    if let scanLabel { Text("· " + scanLabel) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(levelName): \(entry.text)")
        .accessibilityIdentifier("log-row")
    }

    private var symbol: String {
        switch entry.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: .secondary
        case .warning: .yellow
        case .error: .red
        }
    }

    private var levelName: String {
        switch entry.level {
        case .info: "Hinweis"
        case .warning: "Warnung"
        case .error: "Fehler"
        }
    }
}

/// Leiste für den Serienmodus: Serie beginnen und beenden, Auto-Auslösung, Fortschritt bis zur Aufnahme.
struct SeriesBar: View {
    @Bindable var model: AppModel
    /// Vor dem Beginn gewählt: jede Aufnahme ist eine Doppelseite.
    @State private var bookMode = false
    /// Beim Export Text erkennen und unsichtbar ins PDF legen.
    @State private var withOCR = false

    var body: some View {
        HStack(spacing: 12) {
            if let series = model.series {
                Label("\(series.title)" + (model.seriesIsBook ? " · Buch" : ""), systemImage: "books.vertical")
                    .font(.callout.bold())
                    .lineLimit(1)
                Text(pageCountText(series.pages.count))
                    .font(.callout.monospacedDigit())
                    .accessibilityIdentifier("series-page-count")
                Toggle("Automatisch auslösen", isOn: $model.autoTriggerEnabled)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("auto-trigger-toggle")
                Toggle(isOn: $model.soundEnabled) { Label("Ton", systemImage: "speaker.wave.2") }
                    .toggleStyle(.switch)
                    .help("Kurzer Ton, sobald eine Aufnahme gemacht ist: dann darf umgeblättert werden")
                    .accessibilityIdentifier("sound-toggle")
                if model.autoTriggerEnabled {
                    phaseIndicator
                }
                Spacer()
                if let progress = model.exportProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 100)
                    Text("\(progress.done)/\(progress.total)").font(.caption.monospacedDigit())
                } else if let url = model.lastExportURL {
                    Button("PDF zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("export-reveal-button")
                }
                Toggle("Mit Texterkennung", isOn: $withOCR)
                    .toggleStyle(.switch)
                    .help("Macht das PDF durchsuchbar. Kostet etwa 1,5 Sekunden je Seite.")
                    .accessibilityIdentifier("export-ocr-toggle")
                Button("Als PDF exportieren …") { chooseExportTarget(for: series) }
                    .disabled(series.pages.isEmpty || model.exportProgress != nil)
                    .accessibilityIdentifier("series-export-button")
                Button("Serie beenden") { model.endSeries() }
                    .accessibilityIdentifier("series-end-button")
            } else {
                Button {
                    model.startSeries(title: Self.defaultTitle(), book: bookMode)
                } label: {
                    Label("Serie beginnen", systemImage: "books.vertical")
                }
                .disabled(model.status != .ready)
                .help("Mehrere Seiten in ein Dokument aufnehmen")
                .accessibilityIdentifier("series-start-button")
                Toggle("Doppelseiten (Buch)", isOn: $bookMode)
                    .toggleStyle(.switch)
                    .help("Jede Aufnahme wird am Falz in eine linke und eine rechte Seite geteilt")
                    .accessibilityIdentifier("book-mode-toggle")
                Text("Eine Serie sammelt die Aufnahmen als Seiten eines Dokuments und löst nach dem Umblättern selbst aus.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                savedDocumentsMenu
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("series-bar")
    }

    @ViewBuilder private var phaseIndicator: some View {
        switch model.seriesPhase {
        case .waitingForMotion:
            Text("Nächste Seite umblättern").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("series-phase")
        case .moving:
            Text("Bewegung …").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("series-phase")
        case .calm(let seconds):
            HStack(spacing: 6) {
                ProgressView(value: min(seconds, model.seriesCalmDuration), total: model.seriesCalmDuration)
                    .frame(width: 80)
                Text("Ruhig …").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("series-phase")
        }
    }

    /// Gespeicherte Dokumente exportieren, auch nachdem die Serie beendet oder die App neu gestartet wurde.
    @ViewBuilder private var savedDocumentsMenu: some View {
        if let progress = model.exportProgress {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 100)
            Text("\(progress.done)/\(progress.total)").font(.caption.monospacedDigit())
        } else if let url = model.lastExportURL {
            Button("PDF zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
                .accessibilityIdentifier("export-reveal-button")
        }
        if !model.savedDocuments.isEmpty {
            Toggle("Mit Texterkennung", isOn: $withOCR)
                .toggleStyle(.switch)
                .help("Macht das PDF durchsuchbar. Kostet etwa 1,5 Sekunden je Seite.")
                .accessibilityIdentifier("export-ocr-toggle")
            Menu {
                ForEach(model.savedDocuments.prefix(20)) { document in
                    Button("\(document.title) · \(document.pages.count) Seite\(document.pages.count == 1 ? "" : "n")") {
                        chooseExportTarget(for: document)
                    }
                    .disabled(document.pages.isEmpty)
                }
            } label: {
                Label("Dokument als PDF exportieren", systemImage: "square.and.arrow.up")
            }
            .disabled(model.exportProgress != nil)
            .fixedSize()
            .accessibilityIdentifier("saved-documents-menu")
        }
    }

    private func chooseExportTarget(for document: ScanDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.title + ".pdf"
        panel.message = "Das PDF wird aus den Originalen mit den eingestellten Korrekturen erzeugt."
        // Für die Oberflächentests: der Dialog öffnet im Testordner statt in den Ordnern des Nutzers.
        if let dir = ProcessInfo.processInfo.environment["SCANUTIL_EXPORT_DIR"] { panel.directoryURL = URL(fileURLWithPath: dir, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var options = ExportOptions.archive
        options.ocr = withOCR
        Task { await model.exportDocument(document, to: url, options: options) }
    }

    private func pageCountText(_ count: Int) -> String {
        count == 1 ? "1 Seite" : "\(count) Seiten"
    }

    static func defaultTitle(now: Date = Date()) -> String {
        "Serie " + now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

struct ThumbnailCell: View {
    let item: ScanItem
    let selected: Bool
    let needsReview: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = item.display {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100, height: 80)
            } else {
                Rectangle().fill(.quaternary).frame(width: 100, height: 80)
            }
            if needsReview {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).padding(3)
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .accessibilityIdentifier("thumbnail")
    }
}

/// Eine Seite einer Doppelseite mit ihren Korrekturen.
struct BookPageView: View {
    let preview: CGImage?
    let region: PageRegion
    var pixelScale = 1.0
    var fullResolution: (@MainActor () async -> CGImage?)?
    var fullResolutionKey = ""

    private var side: String { region == .left ? "left" : "right" }

    var body: some View {
        Group {
            if let preview {
                ZoomableImageView(
                    image: preview, identifier: "book-\(side)", pixelScale: pixelScale,
                    fullResolution: fullResolution, fullResolutionKey: fullResolutionKey
                )
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            Text(region == .left ? "links" : "rechts").font(.caption2).padding(2).background(.regularMaterial)
        }
        .accessibilityLabel(region == .left ? "Linke Seite" : "Rechte Seite")
        .accessibilityIdentifier("book-page-\(side)")
    }
}

/// Detailansicht eines Scans mit Korrekturen. Alle Änderungen betreffen nur die gespeicherten Parameter, nicht das Original.
struct ScanDetailView: View {
    @Bindable var model: AppModel
    let item: ScanItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if model.isBookScan(item.id) {
                    HStack(alignment: .center, spacing: 6) {
                        ForEach(model.pages(of: item.id)) { page in
                            BookPageView(
                                preview: model.pagePreviews[page.id], region: page.region, pixelScale: pixelScale,
                                fullResolution: { await model.fullResolutionImage(scanID: item.id, pageID: page.id) },
                                fullResolutionKey: page.corrections.cacheKey
                            )
                        }
                    }
                    .padding(6)
                } else if let image = item.display {
                    ZoomableImageView(
                        image: image, identifier: "scan", pixelScale: pixelScale,
                        fullResolution: { await model.fullResolutionImage(scanID: item.id) },
                        fullResolutionKey: item.corrections.cacheKey
                    )
                    .id(item.id)        // ein anderer Scan beginnt wieder eingepasst
                    .padding(6)
                }
                if model.analyzing.contains(item.id) {
                    ProgressView("Analyse läuft …").padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if item.corrections.needsReview || !item.warnings.isEmpty { reviewBanner }
            if model.isBookScan(item.id) {
                bookControls.padding(12)
            } else {
                controls.padding(12)
            }
        }
    }

    /// Wie viele Pixel des Originals ein Pixel der verkleinerten Ansicht darstellt, für die Prozentanzeige des Zooms.
    private var pixelScale: Double {
        item.thumbnail.map { Double(item.record.original.width) / Double(max($0.width, 1)) } ?? 1
    }

    /// Je Seite einer Doppelseite: Zuschnitt und Drehung. Die Korrekturen gehören der Seite, nicht dem Scan.
    private var bookControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Doppelseite: zwei Seiten, geteilt am Falz").font(.callout.bold())
                Spacer()
                Button("Automatisch neu erkennen") { Task { await model.reanalyze(id: item.id) } }
                    .disabled(model.analyzing.contains(item.id))
                    .accessibilityIdentifier("reanalyze-button")
            }
            ForEach(model.pages(of: item.id)) { page in
                let c = page.corrections
                let side = page.region == .left ? "links" : "rechts"
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Zuschnitt \(side)" + (c.crop.source == .manual ? " (manuell)" : c.crop.confidence.map { String(format: " (automatisch, Sicherheit %.2f)", $0) } ?? ""),
                           isOn: Binding(get: { c.crop.enabled }, set: { model.setPageCropEnabled(pageID: page.id, $0) }))
                        .disabled(c.crop.quad == nil)
                        .accessibilityIdentifier("book-crop-\(side)")
                    HStack {
                        Text("Drehung \(side)").font(.callout).frame(width: 90, alignment: .leading)
                        Slider(value: Binding(get: { c.rotation.degrees }, set: { model.setPageRotation(pageID: page.id, degrees: $0) }), in: -15...15, step: 0.05)
                            .accessibilityIdentifier("book-rotation-slider-\(side)")
                        Text(String(format: "%+.2f°", c.rotation.degrees)).font(.callout.monospacedDigit()).frame(width: 64, alignment: .trailing)
                    }
                }
            }
            Text("\(item.record.original.width)×\(item.record.original.height) · SHA-256 \(item.record.original.sha256.prefix(12))…")
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("book-controls")
    }

    private var reviewBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Die Automatik ist unsicher. Bitte prüfen.").font(.callout.bold())
                ForEach(item.warnings, id: \.self) { Text($0).font(.caption) }
                if item.corrections.rotation.source == .automatic, !item.corrections.rotation.enabled, item.corrections.rotation.confidence != nil {
                    Text(String(format: "Vorgeschlagene Drehung: %+.2f° (nicht angewendet)", item.corrections.rotation.degrees)).font(.caption)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(Color.yellow.opacity(0.18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-banner")
    }

    private var controls: some View {
        let c = item.corrections
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Korrekturen anwenden", isOn: Binding(get: { c.enabled }, set: { model.setCorrectionsEnabled(id: item.id, $0) }))
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("master-toggle")
                Spacer()
                Button("Automatisch neu erkennen") { Task { await model.reanalyze(id: item.id) } }
                    .disabled(model.analyzing.contains(item.id))
                    .accessibilityIdentifier("reanalyze-button")
            }
            Toggle(cropLabel(c), isOn: Binding(get: { c.crop.enabled }, set: { model.setCropEnabled(id: item.id, $0) }))
                .disabled(!c.enabled || c.crop.quad == nil)
                .accessibilityIdentifier("crop-toggle")
            Toggle(rotationLabel(c), isOn: Binding(get: { c.rotation.enabled }, set: { model.setRotationEnabled(id: item.id, $0) }))
                .disabled(!c.enabled)
                .accessibilityIdentifier("rotation-toggle")
            HStack {
                Slider(
                    value: Binding(get: { c.rotation.degrees }, set: { model.setRotation(id: item.id, degrees: $0) }),
                    in: -15...15, step: 0.05
                )
                .accessibilityIdentifier("rotation-slider")
                Text(String(format: "%+.2f°", c.rotation.degrees)).font(.callout.monospacedDigit()).frame(width: 64, alignment: .trailing)
                    .accessibilityIdentifier("rotation-value")
            }
            .disabled(!c.enabled)
            Text("\(item.record.original.width)×\(item.record.original.height) · SHA-256 \(item.record.original.sha256.prefix(12))…")
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func cropLabel(_ c: Corrections) -> String {
        "Zuschnitt" + sourceText(c.crop.source, c.crop.confidence, hasValue: c.crop.quad != nil)
    }

    private func rotationLabel(_ c: Corrections) -> String {
        "Drehung" + sourceText(c.rotation.source, c.rotation.confidence, hasValue: c.rotation.confidence != nil || c.rotation.source == .manual)
    }

    private func sourceText(_ source: CorrectionSource, _ confidence: Double?, hasValue: Bool) -> String {
        guard hasValue else { return "" }
        if source == .manual { return " (manuell)" }
        return confidence.map { String(format: " (automatisch, Sicherheit %.2f)", $0) } ?? " (automatisch)"
    }
}

/// Fängt die Leertaste ab, solange das Fenster aktiv ist. Lässt sie durch, wenn gerade in ein Textfeld getippt wird.
@MainActor
final class SpaceKeyMonitor {
    private var token: Any?

    func start(_ action: @escaping @MainActor () -> Void) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isSpace = event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            guard isSpace, !event.isARepeat else { return event }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            action()
            return nil
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
