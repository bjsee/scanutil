import AppKit
import ImagingKit
import ScannerKit
import SwiftUI

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

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText).font(.callout)
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

private struct ThumbnailCell: View {
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
    }
}

/// Detailansicht eines Scans mit Korrekturen. Alle Änderungen betreffen nur die gespeicherten Parameter, nicht das Original.
private struct ScanDetailView: View {
    @Bindable var model: AppModel
    let item: ScanItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image = item.display {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(6)
                }
                if model.analyzing.contains(item.id) {
                    ProgressView("Analyse läuft …").padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if item.corrections.needsReview || !item.warnings.isEmpty { reviewBanner }
            controls.padding(12)
        }
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
    }

    private var controls: some View {
        let c = item.corrections
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Korrekturen anwenden", isOn: Binding(get: { c.enabled }, set: { model.setCorrectionsEnabled(id: item.id, $0) }))
                    .toggleStyle(.switch)
                Spacer()
                Button("Automatisch neu erkennen") { Task { await model.reanalyze(id: item.id) } }
                    .disabled(model.analyzing.contains(item.id))
            }
            Toggle(cropLabel(c), isOn: Binding(get: { c.crop.enabled }, set: { model.setCropEnabled(id: item.id, $0) }))
                .disabled(!c.enabled || c.crop.quad == nil)
            Toggle(rotationLabel(c), isOn: Binding(get: { c.rotation.enabled }, set: { model.setRotationEnabled(id: item.id, $0) }))
                .disabled(!c.enabled)
            HStack {
                Slider(
                    value: Binding(get: { c.rotation.degrees }, set: { model.setRotation(id: item.id, degrees: $0) }),
                    in: -15...15, step: 0.05
                )
                Text(String(format: "%+.2f°", c.rotation.degrees)).font(.callout.monospacedDigit()).frame(width: 64, alignment: .trailing)
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
