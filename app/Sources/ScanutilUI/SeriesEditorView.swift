import AppKit
import ArchiveKit
import ImagingKit
import SwiftUI

/// Das Fenster „Serie bearbeiten“: alle Seiten so, wie sie ins PDF kämen, mit Hinweisen auf Unsicheres, Filter und Werkzeugen.
public struct SeriesEditorView: View {
    @Bindable var model: AppModel
    let documentID: UUID?
    @State private var editor = SeriesEditorModel()

    public init(model: AppModel, documentID: UUID?) { self.model = model; self.documentID = documentID }

    public var body: some View {
        Group {
            if let id = documentID, let document = model.latestDocument(id: id) {
                content(document)
            } else {
                ContentUnavailableView("Keine Serie ausgewählt", systemImage: "books.vertical",
                                       description: Text("Wähle in der Serienliste „Bearbeiten …“."))
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        // Ohne `.contain` gäbe die Kennung des Fensters sie allen Elementen darin und überdeckte deren eigene.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("series-editor")
    }

    private func content(_ document: ScanDocument) -> some View {
        let review = model.review(of: document)
        let visible = editor.visiblePages(of: document, review: review)
        return VStack(spacing: 0) {
            header(document, review: review)
            Divider()
            filterBar(document, review: review)
            Divider()
            HStack(spacing: 0) {
                grid(document, visible: visible, review: review)
                Divider()
                inspector(document, review: review, visible: visible)
                    .frame(width: 320)
            }
        }
        .onAppear { if editor.selectedPageID == nil { editor.selectedPageID = document.pages.first?.id } }
    }

    // MARK: Kopf und Filter

    private func header(_ document: ScanDocument, review: DocumentReview) -> some View {
        HStack {
            Text(document.title).font(.headline)
            Text("\(document.pages.count) Seiten · \(review.uncertainCount) unsicher · \(review.reviewedCount) geprüft")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("editor-summary")
            Spacer()
            if review.needingAttention.count > 0 {
                Text("\(review.needingAttention.count) Seite\(review.needingAttention.count == 1 ? "" : "n") noch offen")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("editor-open-count")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func filterBar(_ document: ScanDocument, review: DocumentReview) -> some View {
        HStack(spacing: 6) {
            ForEach(EditorFilter.allCases) { filter in
                let count = editor.count(filter, document: document, review: review)
                Button { editor.filter = filter } label: {
                    Text("\(filter.title) (\(count))")
                }
                .buttonStyle(.bordered)
                .tint(editor.filter == filter ? .accentColor : nil)
                .accessibilityLabel(filter.title)
                .accessibilityValue("\(count)")
                .accessibilityIdentifier("editor-filter-\(filter.rawValue)")
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: Raster

    private func grid(_ document: ScanDocument, visible: [DocumentPage], review: DocumentReview) -> some View {
        ScrollView {
            if visible.isEmpty {
                Text("Keine Seite passt zu diesem Filter.").foregroundStyle(.secondary).padding(40)
                    .accessibilityIdentifier("editor-empty")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 10)], spacing: 10) {
                ForEach(visible) { page in
                    let number = (document.pages.firstIndex { $0.id == page.id } ?? 0) + 1
                    PageCard(model: model, documentID: document.id, page: page, number: number,
                             review: review.pages[page.id], selected: editor.selectedPageID == page.id)
                        .onTapGesture { editor.selectedPageID = page.id }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("editor-grid")
    }

    // MARK: Werkzeuge

    @ViewBuilder
    private func inspector(_ document: ScanDocument, review: DocumentReview, visible: [DocumentPage]) -> some View {
        if let page = document.pages.first(where: { $0.id == editor.selectedPageID }), let pageReview = review.pages[page.id] {
            let number = (document.pages.firstIndex { $0.id == page.id } ?? 0) + 1
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Seite \(number)").font(.headline)
                    Spacer()
                    Button { editor.step(-1, in: visible) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Vorige Seite").accessibilityIdentifier("editor-prev")
                    Button { editor.step(1, in: visible) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Nächste Seite").accessibilityIdentifier("editor-next")
                }
                findings(pageReview)
                Divider()
                tools(document, page: page)
                Spacer()
                HStack {
                    Button(pageReview.isReviewed ? "Geprüft zurücknehmen" : "Geprüft") {
                        model.setReviewed(!pageReview.isReviewed, documentID: document.id, pageIDs: [page.id])
                        if !pageReview.isReviewed { editor.selectNextNeedingAttention(in: document, review: model.review(of: model.latestDocument(id: document.id) ?? document)) }
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .accessibilityIdentifier("editor-reviewed")
                    Button("Neu erkennen") { Task { await model.reanalyzeScan(documentID: document.id, scanID: page.scanID) } }
                        .help("Verwirft die Änderungen von Hand und lässt die Automatik diesen Scan neu auswerten")
                        .accessibilityIdentifier("editor-reanalyze")
                }
            }
            .padding(12)
        } else {
            Text("Wähle eine Seite.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func findings(_ review: PageReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if review.findings.isEmpty {
                Label("Nichts Auffälliges", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            ForEach(review.findings) { finding in
                FindingRow(finding: finding)
            }
            if review.isReviewed { Label("Geprüft", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor-findings")
    }

    private func tools(_ document: ScanDocument, page: DocumentPage) -> some View {
        let c = page.corrections
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Zuschnitt anwenden", isOn: Binding(get: { c.crop.enabled },
                set: { on in model.updatePage(documentID: document.id, pageID: page.id) { $0.setCropEnabled(on) } }))
                .disabled(c.crop.quad == nil)
                .accessibilityIdentifier("editor-crop")
            if c.handRemoval.hasMask {
                Toggle("Hände und Daumen entfernen", isOn: Binding(get: { c.handRemoval.enabled },
                    set: { on in model.updatePage(documentID: document.id, pageID: page.id) { $0.setHandRemovalEnabled(on) } }))
                    .accessibilityIdentifier("editor-hands")
            }
            HStack {
                Text("Drehung").frame(width: 60, alignment: .leading)
                Slider(value: Binding(get: { c.rotation.degrees },
                    set: { value in model.updatePage(documentID: document.id, pageID: page.id) { $0.setRotation(degrees: value) } }),
                       in: -15...15, step: 0.05)
                    .accessibilityIdentifier("editor-rotation")
                Text(String(format: "%+.2f°", c.rotation.degrees)).font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing)
            }
        }
    }
}

/// Eine Seite im Raster: Vorschau wie im PDF, Nummer, Ampel und Geprüft-Haken.
struct PageCard: View {
    let model: AppModel
    let documentID: UUID
    let page: DocumentPage
    let number: Int
    let review: PageReview?
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                    else { Rectangle().fill(.quaternary).aspectRatio(0.75, contentMode: .fit) }
                }
                .frame(height: 170)
                badge
            }
            Text("\(number)\(page.region == .left ? " links" : page.region == .right ? " rechts" : "")")
                .font(.caption.monospacedDigit())
        }
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .task(id: page.corrections.cacheKey) { image = await model.pagePreview(documentID: documentID, pageID: page.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seite \(number)")
        .accessibilityValue(state)
        .accessibilityIdentifier("editor-page-\(number)")
        .accessibilityAddTraits(.isButton)
    }

    /// Für Bedienungshilfen und Tests: `geprüft`, `problem`, `prüfen`, `hinweis` oder `ok`.
    private var state: String {
        guard let review else { return "ok" }
        if review.isReviewed { return "geprüft" }
        switch review.severity {
        case .problem: return "problem"
        case .check: return "prüfen"
        case .note: return "hinweis"
        case nil: return "ok"
        }
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case "geprüft": Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case "problem": Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        case "prüfen": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case "hinweis": Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}

struct FindingRow: View {
    let finding: Finding

    private var symbol: String {
        switch finding.severity {
        case .problem: "exclamationmark.octagon.fill"
        case .check: "exclamationmark.triangle.fill"
        case .note: "info.circle"
        }
    }

    private var tint: Color {
        switch finding.severity {
        case .problem: .red
        case .check: .orange
        case .note: .secondary
        }
    }

    var body: some View {
        Label(finding.message, systemImage: symbol).foregroundStyle(tint).font(.callout)
    }
}

/// Das Fenster „Serie bearbeiten“, je Serie eines. Bewusst von Hand und nicht als zweite SwiftUI-Szene: Eine zweite Szene ginge
/// beim Start der App von selbst auf (leer) und nähme dem Hauptfenster den Tastaturfokus.
@MainActor
public enum SeriesEditorWindow {
    private static var windows: [UUID: NSWindow] = [:]

    /// Öffnet das Fenster der Serie oder holt das offene nach vorn.
    public static func show(model: AppModel, documentID: UUID) {
        if let window = windows[documentID], window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let title = model.latestDocument(id: documentID)?.title ?? "Serie"
        let window = NSWindow(contentViewController: NSHostingController(rootView: SeriesEditorView(model: model, documentID: documentID)))
        window.title = "Serie bearbeiten – \(title)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.isReleasedWhenClosed = false
        window.center()
        windows[documentID] = window
        window.makeKeyAndOrderFront(nil)
    }
}
