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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Dokumenten-Schnellablage").font(.title3.bold()); Spacer() }
                .padding(.horizontal, 20).frame(height: 56)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    start
                    if !model.openInboxes.isEmpty { openList }
                    if !model.filedURLs.isEmpty { filed }
                }
                .padding(20).frame(maxWidth: 760, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox-page")
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    if model.inboxDirectory == nil {
                        Label("Noch kein Ablageordner.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Button("Einstellungen") { nav.go(.settings) }.buttonStyle(.link).accessibilityIdentifier("inbox-to-settings")
                    } else if let folder = model.inboxDirectory {
                        Text("Ablage: \(folder.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
                    LabeledContent("Ablageordner") {
                        HStack {
                            Text(model.inboxDirectory?.path ?? "nicht festgelegt")
                                .foregroundStyle(model.inboxDirectory == nil ? .orange : .primary)
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 360, alignment: .trailing)
                                .accessibilityIdentifier("settings-inbox-directory")
                            Button("Ändern …") { chooseDirectory() }.accessibilityIdentifier("settings-inbox-directory-button")
                        }
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

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.inboxDirectory
        panel.prompt = "Wählen"
        if panel.runModal() == .OK, let url = panel.url { model.inboxDirectory = url }
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
