import ArchiveKit
import CoreGraphics
import ExportKit
import Foundation
import ImagingKit
import Observation
import ScannerKit

/// Ein gespeicherter Scan mit Ansichten und Korrekturen. Das Original auf der Platte bleibt unverändert.
public struct ScanItem: Identifiable, @unchecked Sendable {
    public let record: ScanRecord
    /// Verkleinerte Ansicht des unveränderten Originals.
    public let thumbnail: CGImage?
    public var corrections: Corrections
    /// Verkleinerte Ansicht mit angewandten Korrekturen.
    public var corrected: CGImage?
    public var warnings: [String]
    public var id: UUID { record.id }

    /// Was die Oberfläche zeigt: mit Korrekturen, wenn es welche gibt.
    public var display: CGImage? { corrected ?? thumbnail }
}

/// Ergebnis der automatischen Analyse für die Oberfläche.
public struct AnalysisResult: @unchecked Sendable {
    public let corrections: Corrections
    public let warnings: [String]

    public init(corrections: Corrections, warnings: [String]) {
        self.corrections = corrections
        self.warnings = warnings
    }
}

/// Ergebnis der automatischen Analyse einer Doppelseite: Korrekturen je Seite.
public struct BookAnalysisResult: @unchecked Sendable {
    public let left: Corrections
    public let right: Corrections
    public let warnings: [String]

    public init(left: Corrections, right: Corrections, warnings: [String]) {
        self.left = left
        self.right = right
        self.warnings = warnings
    }
}

/// Zustand und Abläufe der Oberfläche. Kennt weder SwiftUI noch die Hardware, nur `ScannerPort` und `ArchiveStore`.
@MainActor
@Observable
public final class AppModel {
    public enum Status: Equatable {
        case disconnected
        case connecting
        case ready
        case capturing
        case failed(String)
    }

    public private(set) var status: Status = .disconnected
    public private(set) var device: DeviceInfo?
    public private(set) var previewImage: CGImage?
    public private(set) var scans: [ScanItem] = []
    public private(set) var message: String?
    public private(set) var captureFormat: ScanFormat?
    /// Dauer des letzten Scans vom Tastendruck bis zur archivierten Miniatur, ohne den Neustart der Vorschau.
    public private(set) var lastScanDuration: Duration?

    /// Das Dokument der laufenden Serie, sonst `nil`. Jede Aufnahme der Serie wird als Seite angehängt und sofort gespeichert.
    public private(set) var series: ScanDocument?
    public var isSeriesActive: Bool { series != nil }
    /// Wie lange das Bild ruhig sein muss, bis ausgelöst wird, für den Fortschrittsbalken.
    public var seriesCalmDuration: TimeInterval { trigger.configuration.calmDuration }
    /// Zustand der Auto-Auslösung für die Anzeige (Ruhe-Fortschritt).
    public private(set) var seriesPhase: AutoTrigger.Phase = .waitingForMotion
    /// Ob in der Serie automatisch ausgelöst wird. Aus: nur von Hand, die Seiten kommen trotzdem ins Dokument.
    public var autoTriggerEnabled = true
    /// Ob die Serie Doppelseiten aufnimmt: jede Aufnahme ergibt eine linke und eine rechte Seite.
    public private(set) var seriesIsBook = false
    /// Verkleinerte Ansicht jeder Buchseite mit ihren Korrekturen, nach Seiten-ID.
    public private(set) var pagePreviews: [UUID: CGImage] = [:]
    /// Fortschritt des laufenden PDF-Exports (fertige Seiten, alle Seiten), sonst `nil`.
    public private(set) var exportProgress: (done: Int, total: Int)?
    /// Ort des zuletzt geschriebenen PDFs, für „Im Finder zeigen“.
    public private(set) var lastExportURL: URL?
    public private(set) var lastExportReport: ExportReport?

    public var archiveURL: URL { store.root }
    public var lastScan: ScanItem? { scans.first }

    /// Scans, deren automatische Analyse noch läuft.
    public private(set) var analyzing: Set<UUID> = []
    public var selectedID: UUID?
    public var selectedItem: ScanItem? { scans.first { $0.id == selectedID } }

    private let scanner: any ScannerPort
    private let store: ArchiveStore
    private let thumbnailSize: Int
    private let analyze: @Sendable (CGImage) -> AnalysisResult
    private let analyzeBook: @Sendable (CGImage) -> BookAnalysisResult
    private let recognizer: any TextRecognizer
    private var session: (any ScanSession)?
    private var previewTask: Task<Void, Never>?
    private var trigger = AutoTrigger()
    private var lastSignature: FrameSignature?

    public init(
        scanner: any ScannerPort, store: ArchiveStore, thumbnailSize: Int = 1600,
        analyze: @escaping @Sendable (CGImage) -> AnalysisResult = AppModel.defaultAnalysis,
        analyzeBook: @escaping @Sendable (CGImage) -> BookAnalysisResult = AppModel.defaultBookAnalysis,
        recognizer: any TextRecognizer = VisionTextRecognizer()
    ) {
        self.scanner = scanner
        self.store = store
        self.thumbnailSize = thumbnailSize
        self.analyze = analyze
        self.analyzeBook = analyzeBook
        self.recognizer = recognizer
    }

    /// Standardanalyse: Dokument erkennen, Winkel messen, sichere Ergebnisse anwenden.
    public static let defaultAnalysis: @Sendable (CGImage) -> AnalysisResult = { image in
        let analysis = ImageAnalyzer.analyze(image)
        return AnalysisResult(corrections: ImageAnalyzer.corrections(from: analysis), warnings: analysis.warnings)
    }

    /// Standardanalyse einer Doppelseite: Rand, Falz und Schräglage je Seite.
    public static let defaultBookAnalysis: @Sendable (CGImage) -> BookAnalysisResult = { image in
        let analysis = BookAnalyzer.analyze(image)
        let pages = BookAnalyzer.corrections(from: analysis)
        return BookAnalysisResult(left: pages.left, right: pages.right, warnings: analysis.warnings)
    }

    // MARK: Verbinden

    /// Verbindet den Scanner, öffnet die Sitzung im Aufnahmeformat und lädt vorhandene Scans.
    /// Die Vorschau kommt aus derselben Sitzung wie die Aufnahme.
    public func connect() async {
        guard status != .connecting, status != .capturing, session == nil else { return }
        status = .connecting
        message = nil
        do {
            device = try await scanner.connect()
            let formats = try await scanner.availableFormats()
            guard let format = Self.captureFormat(from: formats) else { throw ScannerError.deviceNotFound }
            captureFormat = format
            await loadExistingScans()
            let opened = try await scanner.openSession(format: format, settings: .archival)
            session = opened
            startPreview(from: opened)
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Beendet die Sitzung und setzt die Geräteeinstellungen zurück. Vor dem Beenden der App aufrufen.
    public func disconnect() async {
        previewTask?.cancel()
        previewTask = nil
        let closing = session
        session = nil
        await closing?.close()
        previewImage = nil
        status = .disconnected
    }

    /// Format: Aufnahme in 5696x4272, falls angeboten, sonst das größte. Nicht blind das größte,
    /// weil die Stufen darüber vom Gerät hochgerechnet und nachgeschärft werden (docs/feasibility.adoc).
    static func captureFormat(from formats: [ScanFormat]) -> ScanFormat? {
        formats.first { $0.width == 5696 && $0.height == 4272 }
            ?? formats.max { $0.width * $0.height < $1.width * $1.height }
    }

    // MARK: Vorschau

    private func startPreview(from session: any ScanSession) {
        previewTask?.cancel()
        previewTask = Task {
            for await frame in session.previewFrames {
                if Task.isCancelled { break }
                self.previewImage = frame.image
                guard self.isSeriesActive, self.status == .ready else { continue }
                let image = frame.image
                let signature = await Task.detached { FrameSignature(image: image) }.value
                if let signature { await self.processSeriesFrame(signature, at: ProcessInfo.processInfo.systemUptime) }
            }
        }
    }

    // MARK: Scannen

    /// Nimmt das nächste Bild der laufenden Sitzung in voller Auflösung auf und archiviert das Original.
    public func scan() async {
        guard status == .ready, let session else { return }
        if series != nil, let lastSignature { trigger.noteManualCapture(of: lastSignature) }
        status = .capturing
        message = nil
        let started = ContinuousClock.now
        do {
            let capture = try await session.capture()
            let record = try store.store(capture)
            let store = self.store, size = thumbnailSize
            let thumb = await Task.detached { store.thumbnail(for: record, maxPixelSize: size) }.value
            let item = ScanItem(record: record, thumbnail: thumb, corrections: .none, corrected: nil, warnings: [])
            scans.insert(item, at: 0)
            selectedID = item.id
            lastScanDuration = ContinuousClock.now - started
            appendToSeries(scanID: record.id)
            status = .ready
            analyzeInBackground(id: item.id)
        } catch {
            message = error.localizedDescription
            status = .ready
        }
    }

    // MARK: Serie

    /// Beginnt eine Serie: ein neues, sofort gespeichertes Dokument, dem jede Aufnahme als Seite angehängt wird.
    /// Mit `book` ergibt jede Aufnahme zwei Seiten (links und rechts), geteilt am erkannten Falz.
    public func startSeries(title: String, book: Bool = false) {
        guard status == .ready, series == nil else { return }
        let document = ScanDocument(title: title)
        do {
            try store.saveDocument(document)
            series = document
            seriesIsBook = book
            pagePreviews = [:]
            trigger = AutoTrigger()
            seriesPhase = trigger.phase
            message = nil
        } catch {
            message = "Die Serie konnte nicht begonnen werden: \(error.localizedDescription)"
        }
    }

    /// Beendet die Serie. Das Dokument bleibt gespeichert.
    public func endSeries() {
        series = nil
        seriesIsBook = false
        seriesPhase = .waitingForMotion
    }

    /// Meldet der Auto-Auslösung ein Vorschaubild. Löst eine Aufnahme aus, wenn die Seite gewechselt hat und Ruhe herrscht.
    func processSeriesFrame(_ signature: FrameSignature, at time: TimeInterval) async {
        lastSignature = signature
        guard series != nil, autoTriggerEnabled, status == .ready else { return }
        let event = trigger.feed(signature, at: time)
        seriesPhase = trigger.phase
        switch event {
        case .none: break
        case .skippedDuplicate: message = "Die Seite ist unverändert, es wurde nicht aufgenommen."
        case .fire: await scan()
        }
    }

    /// Schreibt das Dokument der Serie als PDF. Läuft im Hintergrund; die Serie kann dabei weitergehen,
    /// exportiert wird der Stand beim Aufruf.
    public func exportSeries(to url: URL, options: ExportOptions = .archive) async {
        guard let document = series, exportProgress == nil else { return }
        guard !document.pages.isEmpty else { message = "Die Serie hat noch keine Seiten."; return }
        exportProgress = (0, document.pages.count)
        message = nil
        let exporter = PDFExporter(store: store, recognizer: recognizer)
        do {
            let report = try await Task.detached { () -> ExportReport in
                try exporter.export(document, to: url, options: options) { done, total in
                    Task { @MainActor in self.exportProgress = (done, total) }
                }
            }.value
            lastExportURL = url
            lastExportReport = report
            // Das PDF ist geschrieben; eine fehlgeschlagene Texterkennung wird gemeldet, verwirft es aber nicht.
            if !report.ocrFailures.isEmpty {
                let pages = report.ocrFailures.prefix(10).map(String.init).joined(separator: ", ")
                message = "Die Texterkennung schlug bei \(report.ocrFailures.count) Seite(n) fehl (\(pages)); sie stehen ohne Text im PDF."
            }
        } catch {
            message = "Der Export ist fehlgeschlagen: \(error.localizedDescription)"
        }
        exportProgress = nil
    }

    private func appendToSeries(scanID: UUID) {
        guard var document = series else { return }
        if seriesIsBook {
            document.append(DocumentPage(scanID: scanID, region: .left))
            document.append(DocumentPage(scanID: scanID, region: .right))
        } else {
            document.append(DocumentPage(scanID: scanID))
        }
        saveSeries(document)
    }

    /// Übernimmt die Korrekturen eines Scans in die zugehörige Seite der Serie, denn die Seite trägt sie selbst.
    private func mirrorToSeries(_ item: ScanItem) {
        guard var document = series else { return }
        var changed = false
        for page in document.pages where page.scanID == item.id && page.region == .whole && page.corrections != item.corrections {
            document.updateCorrections(pageID: page.id) { $0 = item.corrections }
            changed = true
        }
        if changed { saveSeries(document) }
    }

    private func saveSeries(_ document: ScanDocument) {
        do {
            try store.saveDocument(document)
            series = document
        } catch {
            message = "Das Dokument konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    // MARK: Archiv

    private func loadExistingScans() async {
        let store = self.store, size = thumbnailSize
        let items: [ScanItem] = await Task.detached {
            let records = (try? store.allRecords()) ?? []
            return records.suffix(20).reversed().map { record -> ScanItem in
                let thumb = store.thumbnail(for: record, maxPixelSize: size)
                let corrections = (try? store.corrections(for: record.id)) ?? .none
                let corrected = thumb.flatMap { CorrectionRenderer.render($0, corrections: corrections) }
                return ScanItem(record: record, thumbnail: thumb, corrections: corrections, corrected: corrected, warnings: [])
            }
        }.value
        scans = items
        selectedID = items.first?.id
    }

    // MARK: Korrekturen

    /// Analysiert einen Scan automatisch und speichert das Ergebnis, außer jemand hat inzwischen von Hand korrigiert.
    private func analyzeInBackground(id: UUID) {
        guard let image = scans.first(where: { $0.id == id })?.thumbnail else { return }
        if isBookScan(id) { Task { await analyzeBookScan(id: id, image: image) }; return }
        analyzing.insert(id)
        let analyze = self.analyze
        Task {
            let result = await Task.detached { analyze(image) }.value
            analyzing.remove(id)
            guard let index = scans.firstIndex(where: { $0.id == id }) else { return }
            // Hat der Nutzer in der Zwischenzeit etwas geändert, gilt das und nicht die Automatik.
            guard scans[index].corrections.revision == 0 else { return }
            apply(result.corrections, warnings: result.warnings, at: index)
        }
    }

    /// Verwirft alle Änderungen und analysiert neu.
    public func reanalyze(id: UUID) async {
        guard let index = scans.firstIndex(where: { $0.id == id }), let image = scans[index].thumbnail else { return }
        if isBookScan(id) { await analyzeBookScan(id: id, image: image, force: true); return }
        analyzing.insert(id)
        let analyze = self.analyze
        let result = await Task.detached { analyze(image) }.value
        analyzing.remove(id)
        guard let current = scans.firstIndex(where: { $0.id == id }) else { return }
        apply(result.corrections, warnings: result.warnings, at: current)
    }

    /// Ob der Scan eine Doppelseite ist, die in zwei Seiten geteilt wird.
    public func isBookScan(_ id: UUID) -> Bool {
        series?.pages.contains { $0.scanID == id && $0.region != .whole } ?? false
    }

    /// Die Seiten eines Scans in der Reihenfolge des Dokuments.
    public func pages(of scanID: UUID) -> [DocumentPage] {
        series?.pages.filter { $0.scanID == scanID } ?? []
    }

    /// `force` verwirft auch manuelle Änderungen, sonst gelten sie vor der Automatik.
    private func analyzeBookScan(id: UUID, image: CGImage, force: Bool = false) async {
        analyzing.insert(id)
        let analyzeBook = self.analyzeBook
        let result = await Task.detached { analyzeBook(image) }.value
        analyzing.remove(id)
        guard var document = series else { return }
        for page in document.pages where page.scanID == id {
            let corrections = page.region == .left ? result.left : result.right
            // Hat der Nutzer die Seite schon angefasst, gilt das und nicht die Automatik.
            guard force || page.corrections.revision == 0 else { continue }
            document.updateCorrections(pageID: page.id) { $0 = corrections }
        }
        saveSeries(document)
        if let index = scans.firstIndex(where: { $0.id == id }) { scans[index].warnings = result.warnings }
        refreshPagePreviews(scanID: id)
    }

    /// Ändert die Korrekturen einer Buchseite, speichert das Dokument und rendert die Seitenansicht neu.
    public func updatePageCorrections(pageID: UUID, _ change: (inout Corrections) -> Void) {
        guard var document = series, let page = document.page(id: pageID) else { return }
        document.updateCorrections(pageID: pageID, change)
        saveSeries(document)
        refreshPagePreviews(scanID: page.scanID)
    }

    public func setPageRotation(pageID: UUID, degrees: Double) { updatePageCorrections(pageID: pageID) { $0.setRotation(degrees: degrees) } }
    public func setPageCropEnabled(pageID: UUID, _ on: Bool) { updatePageCorrections(pageID: pageID) { $0.setCropEnabled(on) } }

    /// Rendert die Ansicht der Seiten eines Scans neu: dieselben Korrekturen wie im PDF, nur kleiner.
    private func refreshPagePreviews(scanID: UUID) {
        guard let image = scans.first(where: { $0.id == scanID })?.thumbnail else { return }
        let pages = self.pages(of: scanID)
        Task {
            let rendered: [(UUID, CGImage?)] = await Task.detached {
                pages.map { ($0.id, CorrectionRenderer.render(image, corrections: PageGeometry.effectiveCorrections(for: $0))) }
            }.value
            for (id, preview) in rendered {
                // Nur übernehmen, wenn die Seite noch dieselben Korrekturen hat wie beim Rendern.
                guard let current = series?.page(id: id), pages.first(where: { $0.id == id })?.corrections == current.corrections else { continue }
                pagePreviews[id] = preview
            }
        }
    }

    private func apply(_ corrections: Corrections, warnings: [String], at index: Int) {
        scans[index].corrections = corrections
        scans[index].warnings = warnings
        persistAndRender(index: index)
    }

    /// Ändert die Korrekturen eines Scans, speichert sie und rendert die Ansicht neu.
    public func updateCorrections(id: UUID, _ change: (inout Corrections) -> Void) {
        guard let index = scans.firstIndex(where: { $0.id == id }) else { return }
        change(&scans[index].corrections)
        persistAndRender(index: index)
    }

    public func setRotation(id: UUID, degrees: Double) { updateCorrections(id: id) { $0.setRotation(degrees: degrees) } }
    public func setRotationEnabled(id: UUID, _ on: Bool) { updateCorrections(id: id) { $0.setRotationEnabled(on) } }
    public func setCropEnabled(id: UUID, _ on: Bool) { updateCorrections(id: id) { $0.setCropEnabled(on) } }
    public func setCorrectionsEnabled(id: UUID, _ on: Bool) { updateCorrections(id: id) { $0.setEnabled(on) } }

    private func persistAndRender(index: Int) {
        let item = scans[index]
        do {
            try store.saveCorrections(item.corrections, for: item.id)
        } catch {
            message = "Die Korrekturen konnten nicht gespeichert werden: \(error.localizedDescription)"
        }
        mirrorToSeries(item)
        guard let image = item.thumbnail else { return }
        let corrections = item.corrections, id = item.id
        Task {
            let rendered = await Task.detached { CorrectionRenderer.render(image, corrections: corrections) }.value
            // Nur übernehmen, wenn inzwischen nicht schon neuere Korrekturen vorliegen.
            guard let current = scans.firstIndex(where: { $0.id == id }), scans[current].corrections == corrections else { return }
            scans[current].corrected = rendered
        }
    }
}
