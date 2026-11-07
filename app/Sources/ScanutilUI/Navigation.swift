import AppKit
import ArchiveKit
import Observation
import SwiftUI

/// Die Seiten der App. Die App ist ein einziges Fenster, dessen Seite sich wie in einer Web-App wechselt.
public enum AppRoute: Hashable, Sendable {
    case capture
    case series
    case editor(UUID)
    case export(UUID)
    case inbox
    case settings
    case log

    /// Der Eintrag der Seitenleiste, zu dem die Seite gehört: der Editor ist eine Unterseite der Serien.
    var section: AppRoute {
        switch self {
        case .editor, .export: .series
        default: self
        }
    }
}

/// Wo man gerade ist und wie man zurückkommt (Zurück-Taste, ⌘[).
@MainActor @Observable
public final class Navigator {
    public private(set) var route: AppRoute
    private var history: [AppRoute] = []

    public init(start: AppRoute = .capture) { route = start }

    public var canGoBack: Bool { !history.isEmpty }

    /// Geht zu einer Seite. Dieselbe Seite noch einmal zu öffnen, ändert nichts und füllt den Verlauf nicht.
    public func go(_ target: AppRoute) {
        guard target != route else { return }
        history.append(route)
        if history.count > 50 { history.removeFirst() }
        route = target
    }

    /// Zurück zur vorigen Seite. Ohne Verlauf bleibt es, wo es ist.
    public func back() {
        guard let previous = history.popLast() else { return }
        route = previous
    }

    /// Wie `back()`, aber ersatzweise zu einer festen Seite, wenn es keinen Verlauf gibt (etwa nach dem Neustart im Editor).
    public func back(fallback: AppRoute) {
        if canGoBack { back() } else { route = fallback }
    }
}

/// Die Seitenleiste: Seiten, Scannerstatus, Archiv.
struct Sidebar: View {
    @Bindable var model: AppModel
    let nav: Navigator
    /// Die Liste der Serien unter „Serien“ ist aufgeklappt.
    @State private var seriesExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Chronik-Scanner").font(.headline).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 14)
            item("Aufnahme", symbol: "camera.aperture", route: .capture, identifier: "nav-capture")
            item("Schnellablage", symbol: "tray.and.arrow.down", route: .inbox, identifier: "nav-inbox",
                 badge: model.isInboxActive ? "läuft" : (model.openInboxes.isEmpty ? nil : "\(model.openInboxes.count)"),
                 value: model.isInboxActive ? "läuft" : "\(model.openInboxes.count) offen")
            HStack(spacing: 2) {
                item("Serien", symbol: "books.vertical", route: .series, identifier: "series-list-button",
                     badge: "\(model.seriesDocuments.count)", value: "\(model.seriesDocuments.count)")
                Button { seriesExpanded.toggle() } label: {
                    Image(systemName: seriesExpanded ? "chevron.down" : "chevron.right").frame(width: 22, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(seriesExpanded ? "Liste der Serien einklappen" : "Liste der Serien ausklappen")
                .accessibilityLabel("Liste der Serien")
                .accessibilityValue(seriesExpanded ? "aufgeklappt" : "zugeklappt")
                .accessibilityIdentifier("nav-series-toggle")
            }
            if seriesExpanded { seriesList }
            item("Meldungen", symbol: model.unseenIssues > 0 ? "exclamationmark.bubble.fill" : "text.bubble", route: .log, identifier: "log-button",
                 badge: model.unseenIssues > 0 ? "\(min(model.unseenIssues, 99))" : nil, badgeIsWarning: true,
                 value: "\(model.unseenIssues) neu, \(model.log.count) insgesamt")
            Spacer()
            item("Einstellungen", symbol: "gearshape", route: .settings, identifier: "nav-settings")
            Divider()
            status
        }
        .padding(12)
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar")
    }

    /// Die Serien zum schnellen Wechseln: Name und Zeitpunkt der letzten Bearbeitung. Ein Klick öffnet die Serie zum Bearbeiten.
    private var seriesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if model.seriesDocuments.isEmpty {
                    Text("Noch keine Serie").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
                }
                ForEach(model.seriesDocuments) { document in seriesRow(document) }
            }
        }
        .frame(maxHeight: 300)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav-series-list")
    }

    private func seriesRow(_ document: ScanDocument) -> some View {
        let selected = nav.route == .editor(document.id) || nav.route == .export(document.id)
        let running = model.series?.id == document.id
        let modified = Self.dateText(document.lastModified)
        return Button { nav.go(.editor(document.id)) } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if running { Circle().fill(Color.red).frame(width: 6, height: 6) }
                    Text(document.title).lineLimit(1).truncationMode(.tail)
                }
                Text(modified).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help("\(document.title) · zuletzt bearbeitet \(modified)")
        .accessibilityLabel(document.title)
        .accessibilityValue("zuletzt bearbeitet \(modified)")
        .accessibilityIdentifier("nav-series-item")
    }

    /// „07.11.2026, 09:12“: Datum und Uhrzeit der letzten Bearbeitung.
    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().hour().minute())
    }

    private func item(_ title: String, symbol: String, route: AppRoute, identifier: String, badge: String? = nil,
                      badgeIsWarning: Bool = false, value: String? = nil) -> some View {
        let selected = nav.route.section == route
        return Button { nav.go(route) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
                if let badge {
                    Text(badge).font(.caption.monospacedDigit()).padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(badgeIsWarning ? Color.orange : Color.secondary.opacity(0.25)))
                        .foregroundStyle(badgeIsWarning ? Color.white : Color.primary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
        .accessibilityIdentifier(identifier)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText).font(.callout).accessibilityIdentifier("status-text")
                    if let message = model.message { Text(message).font(.caption).foregroundStyle(.red) }
                }
            }
            Button("Archiv im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([model.archiveURL]) }
                .buttonStyle(.link).font(.caption)
        }
        .padding(.horizontal, 6).padding(.top, 4)
    }

    private var dotColor: Color {
        switch model.status {
        case .ready: .green
        case .capturing, .connecting: .orange
        case .failed: .red
        case .disconnected: .gray
        }
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
