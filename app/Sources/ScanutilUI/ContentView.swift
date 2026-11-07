import AppKit
import ArchiveKit
import ExportKit
import ImagingKit
import ScannerKit
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @Bindable var model: AppModel
    @State private var nav = Navigator()
    @State private var keyMonitor = SpaceKeyMonitor()

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, nav: nav)
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 600)
        .overlay(alignment: .bottom) { undoBar }
        // Zurück wie im Browser.
        .background(Button("Zurück") { nav.back() }.keyboardShortcut("[", modifiers: .command).opacity(0).accessibilityHidden(true))
        // Die Leertaste löst den Scan aus, aber nur auf der Seite Aufnahme: In der Serienliste soll sie nichts tun.
        // Als Tastenkürzel der Schaltfläche kommt sie nicht an, weil das Fokussystem eine Taste ohne Modifikator abfängt,
        // deshalb ein Monitor auf AppKit-Ebene.
        .onAppear { keyMonitor.start { if nav.route == .capture { Task { await model.scan() } } } }
        .onDisappear { keyMonitor.stop() }
        .task {
            await model.loadArchive()
            await model.connect()
        }
    }

    /// Nach dem Löschen einer Serie: ein Hinweis unten mit „Rückgängig“, kein Dialog. Er verschwindet nach einer Weile von selbst.
    @ViewBuilder private var undoBar: some View {
        if let deleted = model.undoableDeletion {
            HStack(spacing: 14) {
                Text("„\(deleted.title)“ gelöscht. Die Scans bleiben im Archiv.")
                Button("Rückgängig") { model.undoDeleteDocument() }
                    .buttonStyle(.link).accessibilityIdentifier("undo-delete-button")
                Button { model.undoableDeletion = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Hinweis schließen")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(Color(nsColor: .darkGray)))
            .foregroundStyle(.white)
            .padding(.bottom, 20)
            .task(id: deleted.id) {
                try? await Task.sleep(for: .seconds(15))
                if model.undoableDeletion?.id == deleted.id { model.undoableDeletion = nil }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("undo-bar")
        }
    }

    @ViewBuilder private var page: some View {
        switch nav.route {
        case .capture: CaptureView(model: model, nav: nav)
        case .series: SeriesPage(model: model, nav: nav)
        case .editor(let id): SeriesEditorView(model: model, documentID: id, nav: nav).id(id)   // anderer Serie, frischer Zustand
        case .export(let id): ExportPage(model: model, documentID: id, nav: nav).id(id)
        case .log: LogPage(model: model)
        }
    }
}

/// Die Seite Aufnahme: Serienleiste, Vorschau, Scans und der Auslöser.
struct CaptureView: View {
    @Bindable var model: AppModel
    let nav: Navigator

    var body: some View {
        VStack(spacing: 0) {
            SeriesBar(model: model, nav: nav)
            Divider()
            HSplitView {
                previewPane
                    .frame(minWidth: 480)
                scansPane
                    .frame(minWidth: 380, idealWidth: 480)
            }
            Divider()
            captureBar
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

    private var captureBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.scan() }
            } label: {
                Label("Scannen", systemImage: "camera.shutter.button")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.status != .ready)
            .help("Leertaste")
            .accessibilityIdentifier("scan-button")
            if let format = model.captureFormat {
                Text("Aufnahme \(format.description), Schärfe 0 (Archivmodus)" + durationText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
    }

    private var durationText: String {
        guard let d = model.lastScanDuration else { return "" }
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: " · letzter Scan %.1f s", seconds)
    }
}

/// Protokoll der Sitzung: Warnungen der Analyse, übersprungene Dubletten, Fehler des Scanners, Berichte vom Export.
struct LogPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Meldungen").font(.title3.bold())
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
            .padding(.horizontal, 20).frame(height: 56)
            Divider()
            if model.log.isEmpty {
                Text("Keine Meldungen.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LogList(model: model) }
                    .accessibilityLabel("Meldungen")
                    .accessibilityIdentifier("log-list")
            }
        }
        .onAppear { model.markLogSeen() }
        .onChange(of: model.log.count) { model.markLogSeen() }
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
    let nav: Navigator
    /// Vor dem Beginn gewählt: jede Aufnahme ist eine Doppelseite.
    @State private var bookMode = false
    /// Der Dialog „neu oder fortsetzen?“ beim Beginnen, und die Liste der Serien.
    @State private var showStartSheet = false

    var body: some View {
        VStack(spacing: 0) {
            bar
            if showStartSheet {
                Divider()
                StartSeriesSheet(model: model, initialBook: bookMode) { showStartSheet = false }
                    .padding(.horizontal, 10).padding(.vertical, 12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var bar: some View {
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
                Button("PDF ausgeben …") { nav.go(.export(series.id)) }
                    .disabled(series.pages.isEmpty)
                    .accessibilityIdentifier("series-export-button")
                Button("Serie beenden") { model.endSeries() }
                    .accessibilityIdentifier("series-end-button")
            } else {
                Button {
                    // Gibt es schon Serien, fragt ein Dialog: neu beginnen oder in einer fortsetzen. Sonst geht es sofort los.
                    if model.savedDocuments.isEmpty {
                        model.startSeries(title: Self.defaultTitle(), book: bookMode)
                    } else {
                        showStartSheet = true
                    }
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
                if let opened = model.openedDocument {
                    Label("Angesehen: \(opened.title) · \(opened.pages.count) Seite\(opened.pages.count == 1 ? "" : "n")", systemImage: "eye")
                        .font(.callout).lineLimit(1)
                        .accessibilityIdentifier("opened-document-label")
                    Button("Bearbeiten …") { nav.go(.editor(opened.id)) }
                        .disabled(opened.pages.isEmpty)
                        .accessibilityIdentifier("edit-opened-button")
                    Button("Hier fortsetzen") { Task { await model.resumeSeries(id: opened.id) } }
                        .disabled(model.status != .ready)
                        .accessibilityIdentifier("resume-opened-button")
                    Button("Schließen") { Task { await model.closeDocument() } }
                        .accessibilityIdentifier("close-document-button")
                } else {
                    Text("Eine Serie sammelt die Aufnahmen als Seiten eines Dokuments und löst nach dem Umblättern selbst aus.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
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

    private func pageCountText(_ count: Int) -> String {
        count == 1 ? "1 Seite" : "\(count) Seiten"
    }

    static func defaultTitle(now: Date = Date()) -> String { AppModel.defaultSeriesTitle(now: now) }
}

/// Der Dialog beim Beginnen, wenn es schon Serien gibt: eine neue beginnen (mit Namen) oder in einer vorhandenen fortsetzen.
struct StartSeriesSheet: View {
    @Bindable var model: AppModel
    var started: (() -> Void)?
    let done: () -> Void

    private enum Mode: Hashable { case new, resume }
    @State private var mode: Mode = .new
    @State private var name = ""
    @State private var book: Bool
    @State private var resumeID: UUID?

    init(model: AppModel, initialBook: Bool, started: (() -> Void)? = nil, done: @escaping () -> Void) {
        self.model = model
        self.started = started
        self.done = done
        _book = State(initialValue: initialBook)
        _resumeID = State(initialValue: model.savedDocuments.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Serie beginnen").font(.headline)
            Text("Es gibt schon \(model.savedDocuments.count) Serie\(model.savedDocuments.count == 1 ? "" : "n"). Neu beginnen oder in einer fortsetzen?")
                .font(.callout).foregroundStyle(.secondary)
            Picker("", selection: $mode) {
                Text("Neue Serie").tag(Mode.new)
                Text("Fortsetzen").tag(Mode.resume)
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("start-mode-picker")

            switch mode {
            case .new:
                TextField("Name", text: $name, prompt: Text(AppModel.defaultSeriesTitle()))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("series-name-field")
                Toggle("Doppelseiten (Buch)", isOn: $book)
                    .help("Jede Aufnahme wird am Falz in eine linke und eine rechte Seite geteilt")
                    .accessibilityIdentifier("sheet-book-toggle")
            case .resume:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.savedDocuments.prefix(8)) { document in
                        Button { resumeID = document.id } label: {
                            HStack {
                                Image(systemName: resumeID == document.id ? "largecircle.fill.circle" : "circle")
                                Text("\(document.title) · \(document.pages.count) Seite\(document.pages.count == 1 ? "" : "n")")
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(resumeID == document.id ? .isSelected : [])
                        .accessibilityIdentifier("resume-option")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("resume-picker")
                if let chosen = model.savedDocuments.first(where: { $0.id == resumeID }) {
                    Text("Neue Aufnahmen kommen ans Ende von „\(chosen.title)“, als " + (chosen.pages.contains { $0.region != .whole } ? "Doppelseiten." : "Einzelseiten."))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("resume-note")
                }
            }

            HStack {
                Spacer()
                Button("Abbrechen") { done() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("series-sheet-cancel")
                Button("Beginnen") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == .resume && resumeID == nil)
                    .accessibilityIdentifier("series-sheet-confirm")
            }
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("start-series-sheet")
    }

    private func confirm() {
        switch mode {
        case .new:
            model.startSeries(title: name, book: book)
        case .resume:
            if let id = resumeID { Task { await model.resumeSeries(id: id) } }
        }
        started?()
        done()
    }
}

/// Die Seite Serien: neue beginnen, alle ansehen, fortsetzen, bearbeiten, umbenennen, als PDF ausgeben, löschen. Rückfragen stehen
/// in der Zeile selbst.
struct SeriesPage: View {
    @Bindable var model: AppModel
    let nav: Navigator

    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var deleting: PendingDeletion?
    @State private var showStart = false
    /// Die Serie, deren weitere Aktionen aufgeklappt sind. Kein Menü: Menüs sind Popups und liegen über allem anderen.
    @State private var expanded: UUID?

    /// Eine Serie, die gelöscht werden soll, und ob ihre Scans mit.
    struct PendingDeletion: Identifiable {
        let document: ScanDocument
        let withScans: Bool
        var id: UUID { document.id }
        var scanCount: Int { Set(document.pages.map(\.scanID)).count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Serien").font(.title3.bold())
                Text("\(model.savedDocuments.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Neue Serie") { showStart.toggle() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSeriesActive)
                    .help(model.isSeriesActive ? "Es läuft schon eine Serie" : "Eine neue Serie beginnen oder eine fortsetzen")
                    .accessibilityIdentifier("series-new-button")
            }
            .padding(.horizontal, 20).frame(height: 56)
            Divider()
            if showStart {
                StartSeriesSheet(model: model, initialBook: false, started: { nav.go(.capture) }) { showStart = false }
                    .padding(20)
                Divider()
            }
            if model.savedDocuments.isEmpty {
                Text("Noch keine Serie.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.savedDocuments) { document in
                            row(document)
                            if expanded == document.id { actions(document) }
                            if let pending = deleting, pending.document.id == document.id { confirmation(pending) }
                            Divider()
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                    .padding(20)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("series-list-view")
    }

    /// Die Rückfrage vor dem Löschen: ein Streifen unter der Zeile, kein Dialog.
    private func confirmation(_ pending: PendingDeletion) -> some View {
        let pages = "\(pending.document.pages.count) Seite\(pending.document.pages.count == 1 ? "" : "n")"
        let text: String = pending.withScans
            ? "„\(pending.document.title)“ mit \(pages) wird gelöscht, dazu \(pending.scanCount) Scan\(pending.scanCount == 1 ? "" : "s"): "
                + (model.scansAreRecoverable ? "Sie kommen in den Papierkorb und lassen sich dort zurücklegen. " : "Sie werden endgültig gelöscht. ")
                + "Kommt ein Scan auch in einer anderen Serie vor, verschwindet er dort ebenfalls."
            : "„\(pending.document.title)“ mit \(pages) wird gelöscht. Die Scans bleiben im Archiv."
        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Abbrechen") { deleting = nil }.accessibilityIdentifier("series-delete-cancel")
            Button(pending.withScans ? (model.scansAreRecoverable ? "Serie und Scans in den Papierkorb" : "Serie und Scans endgültig löschen") : "Löschen") {
                deleting = nil
                Task { await model.deleteDocument(id: pending.document.id, withScans: pending.withScans) }
            }
            .tint(.red)
            .accessibilityIdentifier("series-delete-confirm")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.red.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("series-delete-strip")
    }

    private func row(_ document: ScanDocument) -> some View {
        let isRunning = model.series?.id == document.id, isOpened = model.openedDocument?.id == document.id
        let review = model.review(of: document)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if renaming == document.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(document) }
                        .onExitCommand { renaming = nil }
                        .accessibilityIdentifier("series-rename-field")
                } else {
                    Text(document.title).font(.callout.bold()).lineLimit(1)
                }
                Text("\(document.pages.contains { $0.region != .whole } ? "Buch" : "Einzelseiten") · "
                     + "\(document.pages.count) Seite\(document.pages.count == 1 ? "" : "n") · "
                     + "zuletzt bearbeitet " + Sidebar.dateText(document.lastModified))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isRunning { Text("läuft").font(.caption).foregroundStyle(.red) }
            else if isOpened { Text("angesehen").font(.caption).foregroundStyle(.secondary) }
            let open = review.needingAttention.count
            if open > 0 {
                Text("\(open) unsicher").font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2))).foregroundStyle(Color.orange)
                    .accessibilityIdentifier("series-unsure-badge")
            } else if !document.pages.isEmpty {
                Text("alle geprüft").font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.18))).foregroundStyle(Color.green)
            }
            if renaming == document.id {
                Button("OK") { commitRename(document) }.accessibilityIdentifier("series-rename-ok")
            } else {
                Button("Ansehen") {
                    Task { await model.openDocument(id: document.id); nav.go(.capture) }
                }
                .disabled(model.isSeriesActive || isOpened)
                .accessibilityIdentifier("series-open-button")
                Button("Fortsetzen") {
                    Task { await model.resumeSeries(id: document.id); nav.go(.capture) }
                }
                .disabled(model.isSeriesActive || model.status != .ready)
                .accessibilityIdentifier("series-resume-button")
                Button("Bearbeiten") { nav.go(.editor(document.id)) }
                    .disabled(document.pages.isEmpty)
                    .accessibilityIdentifier("series-edit-button")
                Button { expanded = expanded == document.id ? nil : document.id } label: { Image(systemName: "ellipsis.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Weitere Aktionen")
                    .accessibilityValue(expanded == document.id ? "aufgeklappt" : "zu")
                    .accessibilityIdentifier("series-menu")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(isRunning || isOpened ? Color.accentColor.opacity(0.10) : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(document.title), \(document.pages.count) Seiten")
        .accessibilityIdentifier("series-row")
    }

    /// Die weiteren Aktionen einer Serie als Streifen unter der Zeile.
    private func actions(_ document: ScanDocument) -> some View {
        HStack(spacing: 10) {
            Button("Umbenennen") { renaming = document.id; renameText = document.title; expanded = nil }
                .accessibilityIdentifier("series-rename-button")
            Button("Als PDF …") { expanded = nil; nav.go(.export(document.id)) }
                .disabled(document.pages.isEmpty)
                .accessibilityIdentifier("series-pdf-button")
            Spacer()
            Button("Nur die Serie löschen …") { deleting = PendingDeletion(document: document, withScans: false); expanded = nil }
                .foregroundStyle(.red)
                .accessibilityIdentifier("series-delete-button")
            Button("Serie und Scans löschen …") { deleting = PendingDeletion(document: document, withScans: true); expanded = nil }
                .foregroundStyle(.red)
                .disabled(document.pages.isEmpty)
                .accessibilityIdentifier("series-delete-scans-button")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("series-actions")
    }

    private func commitRename(_ document: ScanDocument) {
        model.renameDocument(id: document.id, to: renameText)
        renaming = nil
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
    @State private var confirmDelete = false

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
            deleteButton.padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    /// Den Scan löschen: mit Rückfrage in der Ansicht selbst, die sagt, was alles weggeht und ob es sich zurücklegen lässt.
    private var deleteButton: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if confirmDelete {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diesen Scan löschen?").font(.callout.bold())
                        Text(deleteMessage).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Abbrechen") { confirmDelete = false }.accessibilityIdentifier("scan-delete-cancel")
                    Button(model.scansAreRecoverable ? "In den Papierkorb legen" : "Endgültig löschen") {
                        confirmDelete = false
                        Task { await model.deleteScan(id: item.id) }
                    }
                    .tint(.red)
                    .accessibilityIdentifier("scan-delete-confirm")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("scan-delete-strip")
            }
            HStack {
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Label("Scan löschen …", systemImage: "trash") }
                    .disabled(confirmDelete)
                    .accessibilityIdentifier("scan-delete-button")
            }
        }
    }

    private var deleteMessage: String {
        let documents = model.documents(containing: item.id)
        var text = "Das Bild (\(item.record.original.width)×\(item.record.original.height)) mit seinen Korrekturen "
            + (model.scansAreRecoverable ? "kommt in den Papierkorb und lässt sich dort zurücklegen." : "wird endgültig gelöscht.")
        if !documents.isEmpty {
            let list = documents.map { document -> String in
                let pages = document.pages.filter { $0.scanID == item.id }.count
                return "„\(document.title)“ (\(pages) Seite\(pages == 1 ? "" : "n"))"
            }.joined(separator: ", ")
            text += " Es verschwindet auch aus: \(list)."
        }
        return text
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
                    if c.handRemoval.hasMask {
                        Toggle("Hände und Daumen entfernen \(side)",
                               isOn: Binding(get: { c.handRemoval.enabled }, set: { model.setPageHandRemovalEnabled(pageID: page.id, $0) }))
                            .accessibilityIdentifier("book-hands-\(side)")
                    }
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
            // Nur wenn Hände, Daumen oder Marker erkannt wurden.
            if c.handRemoval.hasMask {
                Toggle("Hände und Daumen entfernen" + sourceText(c.handRemoval.source, c.handRemoval.confidence, hasValue: true),
                       isOn: Binding(get: { c.handRemoval.enabled }, set: { model.setHandRemovalEnabled(id: item.id, $0) }))
                    .disabled(!c.enabled)
                    .help("Füllt die Stellen mit dem Papierton der Umgebung. Text unter einem Daumen lässt sich nicht wiederherstellen.")
                    .accessibilityIdentifier("hands-toggle")
            }
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
