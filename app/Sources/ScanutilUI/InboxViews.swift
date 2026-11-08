import AppKit
import ArchiveKit
import SwiftUI

/// Namen für Tasten, die ein Fußtaster typischerweise sendet.
public enum TriggerKey {
    public static func name(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 49: "Leertaste"
        case 36: "Eingabe"
        case 76: "Enter (Ziffernblock)"
        case 48: "Tab"
        case 53: "Esc"
        case 51: "Rückschritt"
        case 123: "Pfeil links"
        case 124: "Pfeil rechts"
        case 125: "Pfeil unten"
        case 126: "Pfeil oben"
        case 116: "Bild hoch"
        case 121: "Bild runter"
        case 96...111, 118, 120, 122: "F-Taste (Code \(keyCode))"
        default: "Taste (Code \(keyCode))"
        }
    }
}

/// Die Seite Schnellablage: starten, offene Ablagen weiter bearbeiten, zuletzt abgelegte PDFs.
struct InboxPage: View {
    @Bindable var model: AppModel
    let nav: Navigator
    @State private var discarding: UUID?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Dokumenten-Schnellablage").font(.title3.bold()); Spacer() }
                .padding(.horizontal, 20).frame(height: 56)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    start
                    dropZone
                    TargetListEditor(model: model)
                    if !model.openInboxes.isEmpty { openList }
                    if !model.filedURLs.isEmpty { filed }
                }
                .padding(20).frame(maxWidth: 760, alignment: .leading)
            }
        }
        // Dateien lassen sich überall auf der Seite ablegen.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FileDrop.urls(from: providers) { urls in Task { @MainActor in await importAndShow(urls) } }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox-page")
    }

    /// Übernimmt Dateien; war keine Aufnahme am Laufen, geht es gleich zum Prüfen und Ablegen.
    private func importAndShow(_ urls: [URL]) async {
        let wasRunning = model.isInboxActive
        if let id = await model.importFiles(urls), !wasRunning { nav.go(.editor(id)) }
    }

    /// Die Fläche zum Ablegen von Dateien und der Weg über die Dateiauswahl.
    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square").font(.title2).foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            Text("PDF-Dateien und Bilder hierher ziehen").font(.callout.bold())
            Text("Sie werden wie ein Scan behandelt: Text wird erkannt, die Dokumente bekommen einen passenden Namen und lassen sich prüfen und ablegen.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if model.isImporting {
                ProgressView("Lese Dateien …").accessibilityIdentifier("inbox-import-progress")
            } else {
                Button("Dateien wählen …") { chooseFiles() }.accessibilityIdentifier("inbox-import-button")
            }
        }
        .frame(maxWidth: .infinity).padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(dropTargeted ? Color.accentColor.opacity(0.10) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox-drop-zone")
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image]
        panel.prompt = "Aufnehmen"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importAndShow(urls) }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.inboxTargets.items.isEmpty {
                HStack(spacing: 8) {
                    Text("Ablegen in:").font(.callout)
                    TargetChips(model: model, selected: model.inboxTargets.activeID) { model.selectInboxTarget(id: $0) }
                }
            }
            if model.isInboxActive {
                Label("Eine Schnellablage läuft: \(model.series?.pages.count ?? 0) Seite(n).", systemImage: "circle.fill")
                    .foregroundStyle(.red)
                Button("Zur Aufnahme") { nav.go(.capture) }.accessibilityIdentifier("inbox-to-capture")
            } else {
                Text("Dokumente unter den Scanner legen und mit dem Fußtaster (oder der Taste „\(TriggerKey.name(model.triggerKeyCode))“) aufnehmen. "
                     + "Jede Aufnahme ist zunächst ein eigenes Dokument; nach „Fertig“ prüfst du sie, fasst zusammen, was zusammengehört, und legst alles als PDF mit Texterkennung ab.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Schnellablage starten") { model.startInbox(); nav.go(.capture) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.status != .ready || model.isSeriesActive)
                        .help(model.isSeriesActive ? "Es läuft schon eine Serie" : "Beginnt die Aufnahme")
                        .accessibilityIdentifier("inbox-start-button")
                    if model.inboxTargets.items.isEmpty {
                        Label("Noch kein Zielordner: Füge unten einen hinzu.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .accessibilityIdentifier("inbox-no-target-hint")
                    }
                }
            }
        }
    }

    private var openList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Noch nicht abgelegt").font(.headline)
            ForEach(model.openInboxes) { document in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.title).font(.callout.bold())
                        Text("\(document.pages.count) Seite(n) · \(document.groups.count) Dokument(e) · zuletzt \(Sidebar.dateText(document.lastModified))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.series?.id == document.id {
                        Text("läuft").font(.caption).foregroundStyle(.red)
                    } else if discarding == document.id {
                        Text("Verwerfen? Die Scans bleiben im Archiv.").font(.caption)
                        Button("Abbrechen") { discarding = nil }.accessibilityIdentifier("inbox-discard-cancel")
                        Button("Verwerfen") { discarding = nil; Task { await model.discardInbox(documentID: document.id) } }
                            .tint(.red).accessibilityIdentifier("inbox-discard-confirm")
                    } else {
                        Button("Bearbeiten und ablegen") { nav.go(.editor(document.id)) }.accessibilityIdentifier("inbox-open-button")
                        Button("Verwerfen …") { discarding = document.id }.accessibilityIdentifier("inbox-discard-button")
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("inbox-open-row")
            }
        }
    }

    private var filed: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Zuletzt abgelegt").font(.headline)
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting(model.filedURLs) }
                    .buttonStyle(.link).accessibilityIdentifier("inbox-reveal-button")
            }
            ForEach(model.filedURLs, id: \.self) { url in
                Label(url.lastPathComponent, systemImage: "doc.richtext").font(.callout)
                    .accessibilityIdentifier("inbox-filed-row")
            }
        }
    }
}

/// Die Seite Einstellungen: Ablageordner, Auslöser-Taste, Namensvorschlag.
struct SettingsPage: View {
    @Bindable var model: AppModel
    @State private var learning = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Einstellungen").font(.title3.bold()); Spacer() }
                .padding(.horizontal, 20).frame(height: 56)
            Divider()
            Form {
                Section("Schnellablage") {
                    LabeledContent("Zielordner") {
                        Text("\(model.inboxTargets.items.count) · auf der Seite Schnellablage")
                            .foregroundStyle(.secondary).accessibilityIdentifier("settings-target-count")
                    }
                    Text("Die PDFs heißen „JJMM Beschreibung.pdf“, etwa „2611 Tierarztpraxis.pdf“, und enthalten durchsuchbaren Text.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Namen mit KI auf dem Mac vorschlagen", isOn: $model.aiNamingEnabled)
                        .disabled(!model.aiNamingAvailable)
                        .accessibilityIdentifier("settings-ai-toggle")
                    Text(model.aiNamingAvailable
                         ? "Der erkannte Text bleibt auf diesem Rechner."
                         : "Apple Intelligence ist auf diesem Mac nicht verfügbar. Der Name kommt dann aus der ersten Textzeile.")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("settings-ai-note")
                }
                Section("Aufnahme") {
                    Toggle("Ton nach jeder Aufnahme", isOn: $model.soundEnabled)
                        .accessibilityIdentifier("settings-sound-toggle")
                    Text("Ein kurzer Ton, sobald das Bild aufgenommen ist: dann darf das nächste Dokument unter den Scanner. Gilt für jede Aufnahme, auch ohne Serie.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Auslöser") {
                    LabeledContent("Taste für die Aufnahme") {
                        HStack {
                            Text(learning ? "Drücke jetzt die Taste …" : TriggerKey.name(model.triggerKeyCode))
                                .accessibilityIdentifier("settings-trigger-key")
                            Button(learning ? "Abbrechen" : "Taste lernen") { learning ? stopLearning() : startLearning() }
                                .accessibilityIdentifier("settings-trigger-learn")
                            Button("Leertaste") { model.triggerKeyCode = 49 }
                                .disabled(model.triggerKeyCode == 49 || learning)
                                .accessibilityIdentifier("settings-trigger-reset")
                        }
                    }
                    Text("Ein Fußtaster sendet meist eine Taste. Hier legst du fest, welche; sie löst auf der Seite Aufnahme aus.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onDisappear { stopLearning() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-page")
    }

    private func startLearning() {
        learning = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return nil }
            if event.keyCode != 53 { model.triggerKeyCode = event.keyCode }   // Esc bricht ab
            stopLearning()
            return nil
        }
    }

    private func stopLearning() {
        learning = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Die Zielordner als Schaltflächen zum Umschalten per Klick. Der gewählte ist hervorgehoben.
struct TargetChips: View {
    let model: AppModel
    let selected: UUID?
    let choose: (UUID) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.inboxTargets.items) { target in
                Button { choose(target.id) } label: {
                    Text(target.displayName).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(selected == target.id ? Color.accentColor : Color.secondary.opacity(0.15)))
                        .foregroundStyle(selected == target.id ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .help(target.path)
                .accessibilityLabel(target.displayName)
                .accessibilityValue(selected == target.id ? "gewählt" : "")
                .accessibilityAddTraits(selected == target.id ? .isSelected : [])
                .accessibilityIdentifier("target-chip")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("target-chips")
    }
}

/// Eine Zeile der Zielordner in den Einstellungen: wählen, Bezeichner, Pfad, Reihenfolge, entfernen.
struct TargetRow: View {
    let model: AppModel
    let target: InboxTarget
    let isFirst: Bool
    let isLast: Bool
    @State private var label = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { model.selectInboxTarget(id: target.id) } label: {
                Image(systemName: model.inboxTargets.activeID == target.id ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.plain).help("Dieses Ziel für neue Aufnahmen wählen")
            .accessibilityLabel("Als Ziel wählen").accessibilityIdentifier("target-select")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Bezeichner (optional)", text: $label)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    .focused($focused)
                    .onSubmit { model.setInboxTargetLabel(label, id: target.id) }
                    .onChange(of: focused) { if !focused { model.setInboxTargetLabel(label, id: target.id) } }
                    .accessibilityLabel("Bezeichner von \(target.path)")
                    .accessibilityIdentifier("target-label-field")
                Text(target.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("target-path")
            }
            Spacer()
            Button { model.moveInboxTarget(id: target.id, up: true) } label: { Image(systemName: "chevron.up") }
                .disabled(isFirst).help("Nach oben").accessibilityLabel("Nach oben").accessibilityIdentifier("target-up")
            Button { model.moveInboxTarget(id: target.id, up: false) } label: { Image(systemName: "chevron.down") }
                .disabled(isLast).help("Nach unten").accessibilityLabel("Nach unten").accessibilityIdentifier("target-down")
            Button(role: .destructive) { model.removeInboxTarget(id: target.id) } label: { Image(systemName: "trash") }
                .help("Aus der Liste entfernen (der Ordner selbst bleibt)").accessibilityLabel("Entfernen").accessibilityIdentifier("target-remove")
        }
        .onAppear { label = target.label }
        .onChange(of: target.label) { label = target.label }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("target-row")
    }
}

/// Die Zielordner anlegen und bearbeiten, direkt auf der Seite Schnellablage: hinzufügen, benennen, ordnen, entfernen.
struct TargetListEditor: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zielordner").font(.headline)
            if model.inboxTargets.items.isEmpty {
                Label("Noch kein Zielordner. Ohne Ziel lässt sich nichts ablegen.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout).accessibilityIdentifier("inbox-no-target")
            }
            ForEach(Array(model.inboxTargets.items.enumerated()), id: \.element.id) { index, target in
                TargetRow(model: model, target: target, isFirst: index == 0, isLast: index == model.inboxTargets.items.count - 1)
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
            Button("Ordner hinzufügen …") { add() }.accessibilityIdentifier("inbox-target-add")
            Text("Beim Aufnehmen wählst du per Klick das Ziel; im Editor lässt es sich je Dokument ändern. Die Reihenfolge bestimmst du mit den Pfeilen, das Entfernen lässt den Ordner selbst unberührt.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox-targets")
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Hinzufügen"
        if panel.runModal() == .OK, let url = panel.url { model.addInboxTarget(path: url.path) }
    }
}
