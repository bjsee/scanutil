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
            await model.connect()
        }
    }

    private var previewPane: some View {
        ZStack {
            Color.black
            if let image = model.previewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if case .failed(let text) = model.status {
                Label(text, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
                    .padding()
                    .multilineTextAlignment(.center)
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
        case .failed: "Nicht verfügbar"
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

    private func chooseExportTarget(for series: ScanDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = series.title + ".pdf"
        panel.message = "Das PDF wird aus den Originalen mit den eingestellten Korrekturen erzeugt."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var options = ExportOptions.archive
        options.ocr = withOCR
        Task { await model.exportSeries(to: url, options: options) }
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

    var body: some View {
        Group {
            if let preview {
                Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .overlay(alignment: .bottom) {
            Text(region == .left ? "links" : "rechts").font(.caption2).padding(2).background(.regularMaterial)
        }
        .accessibilityLabel(region == .left ? "Linke Seite" : "Rechte Seite")
        .accessibilityIdentifier("book-page-\(region == .left ? "left" : "right")")
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
                            BookPageView(preview: model.pagePreviews[page.id], region: page.region)
                        }
                    }
                    .padding(6)
                } else if let image = item.display {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(6)
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
