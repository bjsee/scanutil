import AppKit
import ArchiveKit
import ExportKit
import ImagingKit
import SwiftUI

/// Das Fenster „Serie bearbeiten“: alle Seiten so, wie sie ins PDF kämen, mit Hinweisen auf Unsicheres, Filter und Werkzeugen.
public struct SeriesEditorView: View {
    @Bindable var model: AppModel
    let documentID: UUID?
    let nav: Navigator
    @State private var editor = SeriesEditorModel()
    /// Der Name der Serie wird gerade geändert.
    @State private var renaming = false
    @State private var renameText = ""
    /// Höhe der Seitenkarten im Raster, vom Nutzer einstellbar.
    @State private var cardHeight = 170.0
    /// Was die große Ansicht zeigt. Hier und nicht in der Ansicht, damit die Werkzeuge „Rahmen ziehen“ umschalten können.
    @State private var previewMode = PagePreview.Mode.original

    public init(model: AppModel, documentID: UUID?, nav: Navigator) { self.model = model; self.documentID = documentID; self.nav = nav }

    public var body: some View {
        Group {
            if let id = documentID, let document = model.latestDocument(id: id) {
                content(document)
            } else {
                ContentUnavailableView("Keine Serie ausgewählt", systemImage: "books.vertical",
                                       description: Text("Wähle in der Serienliste „Bearbeiten …“."))
            }
        }
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
            HSplitView {
                grid(document, visible: visible, review: review)
                    .frame(minWidth: 260)
                inspector(document, review: review, visible: visible)
                    .frame(minWidth: 380, idealWidth: 520)
            }
        }
        .onAppear { if editor.selectedPageID == nil { editor.selectedPageID = document.pages.first?.id } }
    }

    // MARK: Kopf und Filter

    private func header(_ document: ScanDocument, review: DocumentReview) -> some View {
        HStack {
            Button { nav.back(fallback: document.isInbox ? .inbox : .series) } label: { Label(document.isInbox ? "Schnellablage" : "Serien", systemImage: "chevron.left") }
                .buttonStyle(.link)
                .accessibilityIdentifier("editor-back")
            Text("›").foregroundStyle(.secondary)
            if renaming {
                TextField("Name der Serie", text: $renameText)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit { commitRename(document) }
                    .onExitCommand { renaming = false }
                    .accessibilityIdentifier("editor-title-field")
                Button("OK") { commitRename(document) }.accessibilityIdentifier("editor-title-ok")
            } else {
                Text(document.title).font(.title3.bold()).lineLimit(1).accessibilityIdentifier("editor-title")
                Button { renameText = document.title; renaming = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Serie umbenennen")
                    .accessibilityLabel("Serie umbenennen").accessibilityIdentifier("editor-rename")
            }
            Text("› Bearbeiten").foregroundStyle(.secondary)
            Text("\(document.pages.count) Seiten · \(review.uncertainCount) unsicher · \(review.reviewedCount) geprüft · "
                 + "zuletzt bearbeitet \(Sidebar.dateText(document.lastModified))")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityIdentifier("editor-summary")
            Spacer()
            if review.needingAttention.count > 0 {
                Text("\(review.needingAttention.count) Seite\(review.needingAttention.count == 1 ? "" : "n") noch offen")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("editor-open-count")
            }
            if document.isInbox {
                inboxFileButton(document)
            } else {
                Button("PDF ausgeben …") { nav.go(.export(document.id)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(document.pages.isEmpty)
                    .accessibilityIdentifier("editor-export")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// „Dokument ablegen“ für die Schnellablage: schreibt alle Dokumente als PDF und geht zurück zur Seite Schnellablage.
    @ViewBuilder
    private func inboxFileButton(_ document: ScanDocument) -> some View {
        if let progress = model.exportProgress {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 120)
            Text("\(progress.done)/\(progress.total)").font(.caption.monospacedDigit()).accessibilityIdentifier("editor-file-progress")
        } else {
            if model.inboxTargets.items.isEmpty {
                Button("Ordner einstellen …") { nav.go(.settings) }.buttonStyle(.link).accessibilityIdentifier("editor-to-settings")
            }
            let count = document.groups.count
            Button(count == 1 ? "Dokument ablegen" : "\(count) Dokumente ablegen") {
                Task {
                    let urls = await model.fileInbox(documentID: document.id)
                    if !urls.isEmpty { nav.go(.inbox) }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(document.pages.isEmpty || model.inboxTargets.items.isEmpty)
            .accessibilityIdentifier("editor-file-button")
        }
    }

    private func commitRename(_ document: ScanDocument) {
        if model.renameDocument(id: document.id, to: renameText) { renaming = false }
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
            Image(systemName: "photo").foregroundStyle(.secondary)
            Slider(value: $cardHeight, in: 100...360).frame(width: 120)
                .accessibilityLabel("Größe der Seiten im Raster")
                .accessibilityIdentifier("editor-card-size")
            Image(systemName: "photo.fill").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: Raster

    private func grid(_ document: ScanDocument, visible: [DocumentPage], review: DocumentReview) -> some View {
        if document.isInbox { return AnyView(inboxGrid(document, visible: visible, review: review)) }
        return AnyView(seriesGrid(document, visible: visible, review: review))
    }

    /// Die Schnellablage: je Dokument eine Gruppe mit Namensfeld, Dateiname und den Seiten.
    private func inboxGrid(_ document: ScanDocument, visible: [DocumentPage], review: DocumentReview) -> some View {
        let visibleIDs = Set(visible.map(\.id))
        return ScrollView {
            if visible.isEmpty {
                Text("Keine Seite passt zu diesem Filter.").foregroundStyle(.secondary).padding(40)
                    .accessibilityIdentifier("editor-empty")
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(document.groups.enumerated()), id: \.element.id) { index, group in
                    let pages = group.pageIDs.compactMap { document.page(id: $0) }.filter { visibleIDs.contains($0.id) }
                    if !pages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            InboxGroupHeader(model: model, documentID: document.id, group: group, number: index + 1,
                                             canMerge: index > 0, firstPageID: group.pageIDs[0])
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: cardHeight * 0.8, maximum: cardHeight * 1.2), spacing: 10)], spacing: 10) {
                                ForEach(pages) { page in
                                    let number = (document.pages.firstIndex { $0.id == page.id } ?? 0) + 1
                                    PageCard(model: model, documentID: document.id, page: page, number: number,
                                             review: review.pages[page.id], selected: editor.selectedPageID == page.id, height: cardHeight)
                                        .onTapGesture { editor.selectedPageID = page.id }
                                }
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("inbox-group")
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("editor-grid")
    }

    private func seriesGrid(_ document: ScanDocument, visible: [DocumentPage], review: DocumentReview) -> some View {
        ScrollView {
            if visible.isEmpty {
                Text("Keine Seite passt zu diesem Filter.").foregroundStyle(.secondary).padding(40)
                    .accessibilityIdentifier("editor-empty")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cardHeight * 0.8, maximum: cardHeight * 1.2), spacing: 10)], spacing: 10) {
                ForEach(visible) { page in
                    let number = (document.pages.firstIndex { $0.id == page.id } ?? 0) + 1
                    PageCard(model: model, documentID: document.id, page: page, number: number,
                             review: review.pages[page.id], selected: editor.selectedPageID == page.id, height: cardHeight)
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
                PagePreview(model: model, documentID: document.id, page: page, mode: $previewMode)
                findings(pageReview)
                Divider()
                tools(document, page: page)
                if document.isInbox, let group = document.group(of: page.id), group.pageIDs.first != page.id {
                    Button("Ab dieser Seite als eigenes Dokument") { model.splitInboxPage(documentID: document.id, pageID: page.id) }
                        .help("Trennt diese und die folgenden Seiten vom Dokument ab")
                        .accessibilityIdentifier("inbox-split-button")
                }
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
        let change: ((inout Corrections) -> Void) -> Void = { model.updatePage(documentID: document.id, pageID: page.id, $0) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Zuschnitt").font(.subheadline.bold())
            HStack {
                Button("Rahmen ziehen") { previewMode = .crop }
                    .help("Zeigt das Original mit vier Ecken, die du mit der Maus ziehst")
                    .accessibilityIdentifier("editor-crop-edit")
                Button(page.region == .whole ? "Ganzes Bild" : "Bildhälfte") {
                    change { $0.setCrop(page.region == .whole ? .full : PageGeometry.half(of: .full, region: page.region)) }
                }
                .help("Setzt den Zuschnitt auf das ganze Bild bzw. die linke oder rechte Hälfte")
                .accessibilityIdentifier("editor-crop-half")
                Toggle("anwenden", isOn: Binding(get: { c.crop.enabled }, set: { on in change { $0.setCropEnabled(on) } }))
                    .disabled(c.crop.quad == nil)
                    .accessibilityIdentifier("editor-crop")
            }
            Text("Drehung").font(.subheadline.bold())
            HStack(spacing: 6) {
                Button { change { $0.setRotation(degrees: max(-15, c.rotation.degrees - 0.1)) } } label: { Image(systemName: "minus") }
                    .help("0,1° gegen den Uhrzeigersinn").accessibilityLabel("Weniger drehen").accessibilityIdentifier("editor-rotation-minus")
                Slider(value: Binding(get: { c.rotation.degrees }, set: { value in change { $0.setRotation(degrees: value) } }),
                       in: -15...15, step: 0.05)
                    .accessibilityIdentifier("editor-rotation")
                Button { change { $0.setRotation(degrees: min(15, c.rotation.degrees + 0.1)) } } label: { Image(systemName: "plus") }
                    .help("0,1° im Uhrzeigersinn").accessibilityLabel("Mehr drehen").accessibilityIdentifier("editor-rotation-plus")
                Text(String(format: "%+.2f°", c.rotation.degrees)).font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing)
                Button("0°") { change { $0.setRotation(degrees: 0) } }.accessibilityIdentifier("editor-rotation-zero")
            }
            if c.handRemoval.hasMask {
                Toggle("Hände und Daumen entfernen", isOn: Binding(get: { c.handRemoval.enabled }, set: { on in change { $0.setHandRemovalEnabled(on) } }))
                    .accessibilityIdentifier("editor-hands")
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
    var height = 170.0
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                    else { Rectangle().fill(.quaternary).aspectRatio(0.75, contentMode: .fit) }
                }
                .frame(height: height)
                badge
            }
            Text("\(number)\(page.region == .left ? " links" : page.region == .right ? " rechts" : "")")
                .font(.caption.monospacedDigit())
        }
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        
        .task(id: "\(page.corrections.cacheKey)/\(AppModel.bucket(Int(height * 2.5)))") { image = await model.pagePreview(documentID: documentID, pageID: page.id, maxPixelSize: Int(height * 2.5)) }
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

/// Kopf eines Dokuments in der Schnellablage: Nummer, Namensfeld, Dateiname und „mit dem vorigen zusammenfassen“.
struct InboxGroupHeader: View {
    let model: AppModel
    let documentID: UUID
    let group: PageGroup
    let number: Int
    let canMerge: Bool
    let firstPageID: UUID
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("Dokument \(number)").font(.callout.bold())
            Text("\(group.pageIDs.count) Seite\(group.pageIDs.count == 1 ? "" : "n")").font(.caption).foregroundStyle(.secondary)
            TextField("Beschreibung, z. B. Tierarztpraxis", text: $text)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                .focused($focused)
                .onSubmit { model.renameInboxGroup(documentID: documentID, groupID: group.id, to: text) }
                .onChange(of: focused) { if !focused { model.renameInboxGroup(documentID: documentID, groupID: group.id, to: text) } }
                .accessibilityLabel("Beschreibung von Dokument \(number)")
                .accessibilityIdentifier("inbox-name-field")
            if !model.inboxTargets.items.isEmpty {
                TargetChips(model: model, selected: model.latestDocument(id: documentID).flatMap { model.inboxTarget(for: group, in: $0)?.id }) {
                    model.setInboxGroupTarget(documentID: documentID, groupID: group.id, targetID: $0)
                }
            }
            Text(model.inboxFileStem(documentID: documentID, group: group) + ".pdf")
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier("inbox-file-name")
            Spacer()
            if canMerge {
                Button("Mit vorigem zusammenfassen") { model.mergeInboxPage(documentID: documentID, pageID: firstPageID) }
                    .help("Macht aus diesem und dem Dokument davor eines")
                    .accessibilityIdentifier("inbox-merge-button")
            }
        }
        .onAppear { text = model.latestDocument(id: documentID).flatMap { $0.name(of: group) } ?? "" }
        .onChange(of: model.latestDocument(id: documentID)?.name(of: group)) { text = model.latestDocument(id: documentID)?.name(of: group) ?? "" }
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

/// Die große Ansicht der gewählten Seite: wahlweise das Original mit dem Zuschnitt, den die App verwendet, oder das Ergebnis
/// fürs PDF. Beide lassen sich zoomen.
struct PagePreview: View {
    enum Mode: String, CaseIterable, Identifiable {
        case original = "Original mit Zuschnitt", result = "Ergebnis", crop = "Rahmen ziehen"
        var id: String { rawValue }
    }

    let model: AppModel
    let documentID: UUID
    let page: DocumentPage
    @Binding var mode: Mode
    @State private var image: CGImage?

    /// Wie viele Pixel des Originals ein Pixel der gezeigten Ansicht darstellt, für die Prozentanzeige des Zooms.
    private func pixelScale(of image: CGImage) -> Double {
        guard mode == .original, let scan = model.scanPixelWidth(documentID: documentID, pageID: page.id) else { return 1 }
        return Double(scan) / Double(max(image.width, 1))
    }

    var body: some View {
        VStack(spacing: 6) {
            Picker("Ansicht", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("editor-preview-mode")
            if mode == .crop {
                CropEditor(model: model, documentID: documentID, page: page)
                    .frame(minHeight: 280, maxHeight: .infinity)
            } else {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    ZoomableImageView(
                        image: image, identifier: "editor-preview", pixelScale: pixelScale(of: image),
                        fullResolution: {
                            switch mode {
                            case .original: await model.pageOriginalWithCrop(documentID: documentID, pageID: page.id, fullResolution: true)
                            case .result: await model.pagePreview(documentID: documentID, pageID: page.id, fullResolution: true)
                            case .crop: nil
                            }
                        },
                        fullResolutionKey: "\(page.id)/\(mode.rawValue)/\(page.corrections.cacheKey)")
                        .id("\(page.id)/\(mode.rawValue)")
                } else {
                    ProgressView()
                }
            }
            .frame(minHeight: 280, maxHeight: .infinity)
            .accessibilityIdentifier("editor-preview")
            }
            Text(mode == .original
                 ? "Grün: Zuschnitt fürs PDF. Orange: unsicher oder nur die Bildhälfte. Gestrichelt: die andere Seite. Dunkel fällt weg."
                 : mode == .result ? "So kommt die Seite ins PDF."
                 : "Ziehe die vier Ecken des Rahmens. Was außerhalb liegt, fällt weg. Die Änderung gilt sofort.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(page.id)/\(mode.rawValue)/\(page.corrections.cacheKey)") {
            switch mode {
            case .original: image = await model.pageOriginalWithCrop(documentID: documentID, pageID: page.id)
            case .result: image = await model.pagePreview(documentID: documentID, pageID: page.id, maxPixelSize: 1792)
            case .crop: break
            }
        }
    }
}

/// Der Zuschnittsrahmen zum Ziehen: das Original, darauf das Viereck mit vier Ecken. Beim Loslassen wird der Rahmen als
/// manueller Zuschnitt gespeichert und gilt sofort.
struct CropEditor: View {
    let model: AppModel
    let documentID: UUID
    let page: DocumentPage
    @State private var image: CGImage?
    /// Der Rahmen während des Ziehens; sonst gilt der gespeicherte.
    @State private var draft: Quad?

    private var stored: Quad { PageGeometry.effectiveCorrections(for: page).crop.quad ?? .full }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    let rect = Self.fit(CGSize(width: image.width, height: image.height), in: geometry.size)
                    let quad = draft ?? stored
                    Image(decorative: image, scale: 1).resizable().frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    Path { path in
                        path.move(to: Self.point(quad.topLeft, rect)); path.addLine(to: Self.point(quad.topRight, rect))
                        path.addLine(to: Self.point(quad.bottomRight, rect)); path.addLine(to: Self.point(quad.bottomLeft, rect))
                        path.closeSubpath()
                    }
                    .stroke(Color.green, lineWidth: 2)
                    .background(Path { path in
                        path.move(to: Self.point(quad.topLeft, rect)); path.addLine(to: Self.point(quad.topRight, rect))
                        path.addLine(to: Self.point(quad.bottomRight, rect)); path.addLine(to: Self.point(quad.bottomLeft, rect))
                        path.closeSubpath()
                    }.fill(Color.green.opacity(0.12)))
                    ForEach(QuadCorner.allCases, id: \.self) { corner in
                        let at = Self.point(corner.point(of: quad), rect)
                        Circle().fill(Color.green).overlay(Circle().stroke(.white, lineWidth: 2))
                            .frame(width: 18, height: 18)
                            .position(at)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("crop-editor"))
                                .onChanged { value in
                                    draft = corner.moved(in: draft ?? stored, to: Self.normalized(value.location, rect))
                                }
                                .onEnded { value in
                                    let result = corner.moved(in: draft ?? stored, to: Self.normalized(value.location, rect))
                                    draft = nil
                                    model.updatePage(documentID: documentID, pageID: page.id) { $0.setCrop(result) }
                                })
                            .accessibilityLabel("Ecke \(corner.rawValue)")
                            .accessibilityIdentifier("editor-crop-handle-\(corner.rawValue)")
                    }
                } else {
                    ProgressView()
                }
            }
            .coordinateSpace(name: "crop-editor")
        }
        .task(id: page.id) { image = await model.pageOriginal(documentID: documentID, pageID: page.id) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor-crop-editor")
    }

    /// Wo ein Bild der Größe `size` in `container` liegt, ganz sichtbar und zentriert.
    static func fit(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / size.width, container.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    static func point(_ n: NormalizedPoint, _ rect: CGRect) -> CGPoint { CGPoint(x: rect.minX + n.x * rect.width, y: rect.minY + n.y * rect.height) }

    static func normalized(_ p: CGPoint, _ rect: CGRect) -> NormalizedPoint {
        NormalizedPoint(x: rect.width > 0 ? (p.x - rect.minX) / rect.width : 0, y: rect.height > 0 ? (p.y - rect.minY) / rect.height : 0)
    }
}
