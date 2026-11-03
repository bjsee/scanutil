import ArchiveKit
import CoreGraphics
import ExportKit
import Foundation
import ImageIO
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

/// Ein Eintrag im Protokoll der App: was geschah, wann und zu welchem Scan.
public struct LogEntry: Identifiable, Equatable, Sendable {
    public enum Level: String, Sendable { case info, warning, error }

    public let id = UUID()
    public let time: Date
    public let level: Level
    public let text: String
    /// Der Scan, auf den sich der Eintrag bezieht, falls einer.
    public let scanID: UUID?
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
    /// Die App sucht den Scanner im Hintergrund weiter, weil die Verbindung fehlschlug. Sobald er da ist, verbindet sie sich.
    public private(set) var isSearching = false
    public private(set) var device: DeviceInfo?
    public private(set) var previewImage: CGImage?
    public private(set) var scans: [ScanItem] = []
    public private(set) var message: String?
    /// Alle Meldungen dieser Sitzung, neueste zuerst. Anders als `message` bleiben sie stehen.
    public private(set) var log: [LogEntry] = []
    /// Warnungen und Fehler seit dem letzten Öffnen des Protokolls.
    public private(set) var unseenIssues = 0
    public private(set) var captureFormat: ScanFormat?
    /// Dauer des letzten Scans vom Tastendruck bis zur archivierten Miniatur, ohne den Neustart der Vorschau.
    public private(set) var lastScanDuration: Duration?

    /// Das Dokument der laufenden Serie, sonst `nil`. Jede Aufnahme der Serie wird als Seite angehängt und sofort gespeichert.
    public private(set) var series: ScanDocument?
    /// Das Dokument, das gerade angesehen wird, wenn keine Serie läuft. Es bestimmt, welche Seiten die Scans der Miniaturleiste haben.
    public private(set) var openedDocument: ScanDocument?
    /// Das Dokument, dessen Seiten angezeigt und bearbeitet werden: die laufende Serie, sonst das geöffnete Dokument.
    public var shownDocument: ScanDocument? { series ?? openedDocument }
    public var isSeriesActive: Bool { series != nil }
    /// Wie lange das Bild ruhig sein muss, bis ausgelöst wird, für den Fortschrittsbalken.
    public var seriesCalmDuration: TimeInterval { trigger.configuration.calmDuration }
    /// Zustand der Auto-Auslösung für die Anzeige (Ruhe-Fortschritt).
    public private(set) var seriesPhase: AutoTrigger.Phase = .waitingForMotion
    /// Ob in der Serie automatisch ausgelöst wird. Aus: nur von Hand, die Seiten kommen trotzdem ins Dokument.
    public var autoTriggerEnabled = true
    /// Ob in einer Serie bei jeder Aufnahme ein kurzer Ton kommt. Die Einstellung bleibt erhalten.
    public var soundEnabled: Bool {
        didSet { defaults?.set(soundEnabled, forKey: Self.soundKey) }
    }
    /// Ob die Serie Doppelseiten aufnimmt: jede Aufnahme ergibt eine linke und eine rechte Seite.
    public private(set) var seriesIsBook = false
    /// Verkleinerte Ansicht jeder Buchseite mit ihren Korrekturen, nach Seiten-ID.
    public private(set) var pagePreviews: [UUID: CGImage] = [:]
    /// Alle gespeicherten Dokumente (Serien) des Archivs, neueste zuerst. Auch eine beendete Serie bleibt hier erhalten
    /// und lässt sich exportieren.
    public private(set) var savedDocuments: [ScanDocument] = []
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
    private var searchTask: Task<Void, Never>?
    private let retryInterval: Duration?
    private let sound: any CaptureSound
    private let defaults: UserDefaults?
    /// Wie gelöschte Scans entsorgt werden. Das Modell ist von sich aus endgültig und damit für Tests sicher: Erst die App
    /// übergibt den Papierkorb.
    private let scanDisposal: ScanDisposal
    private static let soundKey = "captureSoundEnabled"
    /// Aus nach `disconnect()`: ein Versuch, der erst danach scheitert, darf die Suche nicht neu starten.
    private var searchAllowed = true
    /// Beobachtet die laufende Sitzung auf Verlust der Verbindung. `sessionGeneration` trennt alte von neuen Sitzungen.
    private var lossTask: Task<Void, Never>?
    private var sessionGeneration = 0
    /// Die Scans werden nur beim ersten Verbinden vom Archiv geladen: ein Wiederverbinden nach einem Verlust darf
    /// Ansichten, Korrekturen und die Auswahl nicht wegwerfen.
    private var hasLoadedScans = false
    private var trigger = AutoTrigger()
    private var lastSignature: FrameSignature?
    /// Zuletzt berechnete Bilder in voller Auflösung. Ein 24-Megapixel-Bild belegt rund 100 MB: höchstens zwei.
    private var fullResolutionCache: [(key: String, corrections: Corrections, image: CGImage)] = []

    public init(
        scanner: any ScannerPort, store: ArchiveStore, thumbnailSize: Int = 1600,
        analyze: @escaping @Sendable (CGImage) -> AnalysisResult = AppModel.defaultAnalysis,
        analyzeBook: @escaping @Sendable (CGImage) -> BookAnalysisResult = AppModel.defaultBookAnalysis,
        recognizer: any TextRecognizer = VisionTextRecognizer(),
        retryInterval: Duration? = .seconds(2),
        sound: any CaptureSound = SilentSound(),
        defaults: UserDefaults? = nil,
        scanDisposal: ScanDisposal = .permanent
    ) {
        self.scanDisposal = scanDisposal
        self.retryInterval = retryInterval
        self.sound = sound
        self.defaults = defaults
        // Ohne gespeicherte Einstellung ist der Ton an.
        soundEnabled = defaults?.object(forKey: Self.soundKey) as? Bool ?? true
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

    // MARK: Protokoll

    /// Höchstzahl der Einträge; ältere fallen heraus.
    static let logLimit = 500

    /// Trägt eine Meldung ins Protokoll ein. Warnungen und Fehler stehen zusätzlich als rote Zeile in `message`,
    /// außer sie gehören zu einem Scan und stehen dort schon im Hinweis (`asMessage: false`).
    func post(_ level: LogEntry.Level, _ text: String, scanID: UUID? = nil, asMessage: Bool = true) {
        log.insert(LogEntry(time: Date(), level: level, text: text, scanID: scanID), at: 0)
        if log.count > Self.logLimit { log.removeLast(log.count - Self.logLimit) }
        if level != .info {
            unseenIssues += 1
            if asMessage { message = text }
        }
    }

    /// Das Protokoll wurde angesehen.
    public func markLogSeen() { unseenIssues = 0 }

    public func clearLog() {
        log = []
        unseenIssues = 0
    }

    /// Das Protokoll als Text, ältestes zuerst, zum Kopieren und Weitergeben.
    public var logText: String {
        let format = Date.ISO8601FormatStyle(timeZone: .current)
        return log.reversed().map { entry in
            let level = switch entry.level { case .info: "INFO   "; case .warning: "WARNUNG"; case .error: "FEHLER " }
            return "\(entry.time.formatted(format)) \(level) \(entry.text)"
        }.joined(separator: "\n")
    }

    // MARK: Verbinden

    /// Verbindet den Scanner, öffnet die Sitzung im Aufnahmeformat und lädt vorhandene Scans.
    /// Die Vorschau kommt aus derselben Sitzung wie die Aufnahme.
    public func connect() async {
        searchAllowed = true
        _ = await attemptConnect()
    }

    /// Ein Verbindungsversuch. Scheitert er, sucht die App im Hintergrund weiter (`startSearching`), denn der Scanner
    /// wird oft erst nach dem Start der App eingeschaltet. Gibt zurück, ob die Verbindung steht.
    @discardableResult
    private func attemptConnect() async -> Bool {
        guard status != .connecting, status != .capturing, session == nil else { return session != nil }
        let previous = status
        // Während der Suche bleibt die Anzeige ruhig: kein Wechsel zu „Verbinde …“ im Takt der Versuche.
        if !isSearching { status = .connecting }
        message = nil
        do {
            device = try await scanner.connect()
            let formats = try await scanner.availableFormats()
            guard let format = Self.captureFormat(from: formats) else { throw ScannerError.deviceNotFound }
            captureFormat = format
            await loadArchive()
            let opened = try await scanner.openSession(format: format, settings: .archival)
            // Wurde die Suche inzwischen abgebrochen (disconnect), darf keine Sitzung offen bleiben:
            // sie hielte die Schärfe im Gerät verstellt.
            if Task.isCancelled { await opened.close(); return false }
            session = opened
            startPreview(from: opened)
            watchConnection(of: opened)
            searchTask?.cancel()
            searchTask = nil
            isSearching = false
            status = .ready
            post(.info, "Verbunden mit \(device?.name ?? "Scanner"), Aufnahme \(format.description).")
            return true
        } catch {
            // Nach disconnect() ist es vorbei: ein Versuch, der erst jetzt scheitert, ändert weder Status noch Protokoll
            // und startet keine neue Suche.
            guard searchAllowed else { return false }
            // Nach einem Verlust ist „Scanner nicht gefunden“ dieselbe Ursache: die Anzeige bleibt beim Verlust,
            // solange die Suche läuft. Ein anderer Fehler (etwa verweigerter Kamerazugriff) ersetzt sie.
            if previous == .failed(Self.connectionLostText), (error as? ScannerError) == .deviceNotFound {
                startSearching()
                return false
            }
            let text = error.localizedDescription
            // Derselbe Fehler wie beim letzten Versuch steht schon im Protokoll: nicht alle paar Sekunden erneut.
            if previous != .failed(text) { post(.error, text, asMessage: false) }
            status = .failed(text)
            startSearching()
            return false
        }
    }

    /// Versucht es regelmäßig erneut, bis der Scanner da ist oder `disconnect()` aufgerufen wird.
    private func startSearching() {
        guard searchTask == nil, let interval = retryInterval else { return }
        isSearching = true
        searchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                if await self.attemptConnect() { return }
            }
        }
    }

    static let connectionLostText = "Die Verbindung zum Scanner ging verloren. Ist er noch angeschlossen und eingeschaltet?"

    /// Wartet darauf, dass die Sitzung den Verlust der Verbindung meldet, und reagiert darauf.
    private func watchConnection(of opened: any ScanSession) {
        lossTask?.cancel()
        sessionGeneration += 1
        let generation = sessionGeneration
        lossTask = Task { [weak self] in
            for await _ in opened.connectionLost {
                guard let self, !Task.isCancelled, self.sessionGeneration == generation else { return }
                await self.handleConnectionLoss()
                return
            }
        }
    }

    /// Der Scanner wurde abgezogen oder ausgeschaltet: Vorschau und Sitzung wegräumen und von vorn suchen,
    /// bis er wieder da ist. Eine laufende Serie und alle Scans bleiben erhalten. Wiederholbar ohne Wirkung.
    private func handleConnectionLoss() async {
        guard let lost = session else { return }
        session = nil
        sessionGeneration += 1
        previewTask?.cancel()
        previewTask = nil
        lossTask = nil
        previewImage = nil          // ein eingefrorenes Bild wäre schlimmer als keines
        await lost.close()
        // Wurde inzwischen beendet (disconnect), ist es vorbei. Sonst wird der Zustand in einem Zug veröffentlicht:
        // erst jetzt ist die alte Sitzung zu, der Status „verloren“ gesetzt und die Suche gestartet.
        guard searchAllowed else { return }
        status = .failed(Self.connectionLostText)
        post(.error, Self.connectionLostText, asMessage: false)
        startSearching()
    }

    /// Beendet die Sitzung und setzt die Geräteeinstellungen zurück. Vor dem Beenden der App aufrufen.
    public func disconnect() async {
        searchAllowed = false
        sessionGeneration += 1
        lossTask?.cancel()
        lossTask = nil
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
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
            // Der Ton kommt, sobald das Bild da ist, nicht erst nach dem Speichern: Ab jetzt darf umgeblättert werden.
            if series != nil, soundEnabled { sound.play() }
            let record = try store.store(capture)
            let store = self.store, size = thumbnailSize
            let thumb = await Task.detached { store.thumbnail(for: record, maxPixelSize: size) }.value
            let item = ScanItem(record: record, thumbnail: thumb, corrections: .none, corrected: nil, warnings: [])
            scans.insert(item, at: 0)
            selectedID = item.id
            lastScanDuration = ContinuousClock.now - started
            appendToSeries(scanID: record.id)
            // Ging die Verbindung während der Aufnahme verloren, bleibt der Status bei „verloren“.
            if self.session != nil { status = .ready }
            analyzeInBackground(id: item.id)
        } catch {
            // „Gerät nicht gefunden“ mitten in einer Aufnahme heißt: der Scanner ist weg.
            if (error as? ScannerError) == .deviceNotFound {
                await handleConnectionLoss()
                if self.session == nil { return }
            }
            post(.error, error.localizedDescription)
            if self.session != nil { status = .ready }
        }
    }

    // MARK: Serie

    /// Beginnt eine Serie: ein neues, sofort gespeichertes Dokument, dem jede Aufnahme als Seite angehängt wird.
    /// Mit `book` ergibt jede Aufnahme zwei Seiten (links und rechts), geteilt am erkannten Falz.
    public func startSeries(title: String, book: Bool = false) {
        guard status == .ready, series == nil else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = ScanDocument(title: trimmed.isEmpty ? Self.defaultSeriesTitle() : trimmed)
        do {
            try store.saveDocument(document)
            // Wurde gerade eine andere Serie angesehen, zeigt die Miniaturleiste deren Scans: die neue Serie beginnt leer.
            if openedDocument != nil { scans = []; selectedID = nil }
            openedDocument = nil
            series = document
            updateSavedDocuments(with: document)
            seriesIsBook = book
            pagePreviews = [:]
            trigger = AutoTrigger()
            seriesPhase = trigger.phase
            message = nil
            post(.info, "Serie „\(document.title)“ begonnen" + (book ? " (Doppelseiten)." : "."))
        } catch {
            post(.error, "Die Serie konnte nicht begonnen werden: \(error.localizedDescription)")
        }
    }

    /// Beendet die Serie. Das Dokument bleibt gespeichert und geöffnet: Seiten und Regler einer Doppelseite bleiben da.
    public func endSeries() {
        if let series { post(.info, "Serie „\(series.title)“ beendet: \(series.pages.count) Seite(n).") }
        openedDocument = series
        series = nil
        seriesIsBook = false
        seriesPhase = .waitingForMotion
    }

    /// Ein Name für eine neue Serie, wenn der Nutzer keinen vergibt: das Datum mit Uhrzeit.
    public static func defaultSeriesTitle(now: Date = Date()) -> String {
        "Serie " + now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// Setzt eine gespeicherte Serie fort: Neue Aufnahmen kommen ans Ende desselben Dokuments, im selben Modus (Einzelseiten oder
    /// Doppelseiten, aus den vorhandenen Seiten abgelesen; `book` gilt nur für ein noch leeres Dokument).
    public func resumeSeries(id: UUID, book: Bool = false) async {
        guard status == .ready, series == nil, let document = savedDocuments.first(where: { $0.id == id }) else { return }
        openedDocument = nil
        series = document          // vor dem Laden, damit die Seiten der Scans bekannt sind
        seriesIsBook = document.pages.isEmpty ? book : document.pages.contains { $0.region != .whole }
        await showScans(of: document)
        trigger = AutoTrigger()
        seriesPhase = trigger.phase
        message = nil
        post(.info, "Serie „\(document.title)“ fortgesetzt (\(document.pages.count) Seite(n)" + (seriesIsBook ? ", Doppelseiten)." : ")."))
    }

    /// Öffnet eine gespeicherte Serie zum Ansehen: Die Miniaturleiste zeigt deren Scans, Seiten und Korrekturen lassen sich bearbeiten.
    /// Nicht möglich, solange eine Serie läuft.
    public func openDocument(id: UUID) async {
        guard series == nil, let document = savedDocuments.first(where: { $0.id == id }) else { return }
        openedDocument = document
        await showScans(of: document)
    }

    /// Schließt die angesehene Serie. Die Miniaturleiste zeigt wieder die letzten Scans des Archivs.
    public func closeDocument() async {
        guard series == nil, openedDocument != nil else { return }
        openedDocument = nil
        pagePreviews = [:]
        await loadExistingScans()
    }

    /// Gibt einer Serie einen Namen. Leere Namen werden abgelehnt. Gibt zurück, ob der Name gilt.
    @discardableResult
    public func renameDocument(id: UUID, to title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { post(.warning, "Der Name einer Serie darf nicht leer sein."); return false }
        var candidates: [ScanDocument?] = [series, openedDocument]
        candidates.append(savedDocuments.first { $0.id == id })
        guard var document = candidates.compactMap({ $0 }).first(where: { $0.id == id }) else { return false }
        guard document.title != trimmed else { return true }
        document.title = trimmed
        document.revision += 1
        commit(document)
        return true
    }

    /// Löscht eine Serie, also ihre Seitenliste. Die Scans (Originale) bleiben im Archiv: Sie sind schreibgeschützt und gehören zu
    /// historischen Vorlagen. Läuft die Serie gerade, endet sie.
    /// - Parameter withScans: Löscht auch die Scans der Serie (in den Papierkorb, wenn die App ihn übergeben hat). Sonst bleiben sie.
    public func deleteDocument(id: UUID, withScans: Bool = false) async {
        guard let document = savedDocuments.first(where: { $0.id == id }) else { return }
        var seen = Set<UUID>()
        let scanIDs = document.pages.map(\.scanID).filter { seen.insert($0).inserted }
        do { try store.deleteDocument(id: id) } catch {
            post(.error, "Die Serie konnte nicht gelöscht werden: \(error.localizedDescription)")
            return
        }
        if series?.id == id { series = nil; seriesIsBook = false; seriesPhase = .waitingForMotion }
        savedDocuments.removeAll { $0.id == id }
        for page in document.pages { pagePreviews[page.id] = nil }
        if openedDocument?.id == id {
            openedDocument = nil
            await loadExistingScans()
        }
        if withScans {
            post(.info, "Serie „\(document.title)“ gelöscht (\(document.pages.count) Seite(n)).")
            await removeScans(scanIDs)
        } else {
            post(.info, "Serie „\(document.title)“ gelöscht (\(document.pages.count) Seite(n)). Die Scans bleiben im Archiv.")
        }
    }

    /// Ob gelöschte Scans in den Papierkorb kommen und sich zurücklegen lassen.
    public var scansAreRecoverable: Bool { scanDisposal.isRecoverable }

    /// Die Serien, in denen ein Scan vorkommt. Ein gelöschter Scan verschwindet aus allen.
    public func documents(containing scanID: UUID) -> [ScanDocument] {
        savedDocuments.filter { $0.pages.contains { $0.scanID == scanID } }
    }

    /// Löscht einen Scan: Original, Eintrag und Korrekturen (in den Papierkorb, wenn die App ihn übergeben hat). Er verschwindet
    /// auch aus allen Serien, in denen er vorkam, bei einer Doppelseite mit beiden Seiten.
    public func deleteScan(id: UUID) async {
        await removeScans([id])
    }

    /// Entfernt Scans aus dem Archiv und bereinigt alles, was sie kennt: Serien, Miniaturleiste, Auswahl, Zwischenspeicher.
    private func removeScans(_ ids: [UUID]) async {
        var removed: [UUID] = []
        for id in ids {
            do {
                try store.deleteScan(id: id, disposal: scanDisposal)
                removed.append(id)
            } catch {
                post(.error, "Der Scan konnte nicht gelöscht werden: \(error.localizedDescription)")
            }
        }
        guard !removed.isEmpty else { return }
        let gone = Set(removed)

        // Seiten, die auf die gelöschten Scans verweisen, aus allen Serien nehmen. Die aktuellste Fassung zählt: die laufende
        // Serie oder das angesehene Dokument kann neuer sein als die Liste.
        for listed in savedDocuments where listed.pages.contains(where: { gone.contains($0.scanID) }) {
            var document = [series, openedDocument].compactMap { $0 }.first { $0.id == listed.id } ?? listed
            for page in document.pages where gone.contains(page.scanID) { pagePreviews[page.id] = nil }
            document.pages.removeAll { gone.contains($0.scanID) }
            document.revision += 1
            commit(document)
        }
        scans.removeAll { gone.contains($0.id) }
        if let selected = selectedID, gone.contains(selected) { selectedID = scans.first?.id }
        analyzing.subtract(gone)
        fullResolutionCache.removeAll { cached in gone.contains { cached.key.hasPrefix($0.uuidString) } }

        let count = removed.count
        let noun = count == 1 ? "Scan" : "Scans"
        post(.info, scanDisposal.isRecoverable
            ? "\(count) \(noun) in den Papierkorb gelegt. Mit „Zurücklegen“ im Papierkorb kommen sie an ihren Platz im Archiv zurück."
            : "\(count) \(noun) gelöscht.")
    }

    /// Lädt die Scans eines Dokuments in die Miniaturleiste, in der Reihenfolge der Seiten, den neuesten zuerst. Fehlende Originale
    /// werden übersprungen.
    private func showScans(of document: ScanDocument) async {
        let store = self.store, size = thumbnailSize
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for page in document.pages where seen.insert(page.scanID).inserted { ids.append(page.scanID) }
        // Einzelseiten tragen ihre Korrekturen im Dokument, Doppelseiten je Seite.
        var wholePageCorrections: [UUID: Corrections] = [:]
        for page in document.pages where page.region == .whole { wholePageCorrections[page.scanID] = page.corrections }
        let corrections = wholePageCorrections
        let items: [ScanItem] = await Task.detached {
            ids.reversed().compactMap { id -> ScanItem? in
                guard let record = try? store.load(id: id) else { return nil }
                let thumb = store.thumbnail(for: record, maxPixelSize: size)
                let c = corrections[id] ?? (try? store.corrections(for: id)) ?? .none
                let corrected = thumb.flatMap { CorrectionRenderer.render($0, corrections: c) }
                return ScanItem(record: record, thumbnail: thumb, corrections: c, corrected: corrected, warnings: [])
            }
        }.value
        scans = items
        selectedID = items.first?.id
        pagePreviews = [:]
        for item in items where isBookScan(item.id) { refreshPagePreviews(scanID: item.id) }
    }

    /// Meldet der Auto-Auslösung ein Vorschaubild. Löst eine Aufnahme aus, wenn die Seite gewechselt hat und Ruhe herrscht.
    func processSeriesFrame(_ signature: FrameSignature, at time: TimeInterval) async {
        lastSignature = signature
        guard series != nil, autoTriggerEnabled, status == .ready else { return }
        let event = trigger.feed(signature, at: time)
        seriesPhase = trigger.phase
        switch event {
        case .none: break
        case .skippedDuplicate: post(.warning, "Die Seite ist unverändert, es wurde nicht aufgenommen.")
        case .fire: await scan()
        }
    }

    /// Schreibt das Dokument der laufenden Serie als PDF. Läuft im Hintergrund; die Serie kann dabei weitergehen,
    /// exportiert wird der Stand beim Aufruf.
    public func exportSeries(to url: URL, options: ExportOptions = .archive) async {
        guard let document = series else { return }
        await exportDocument(document, to: url, options: options)
    }

    /// Schreibt ein gespeichertes Dokument als PDF, auch eine längst beendete Serie. Die Seiten tragen ihre Korrekturen
    /// aus dem Archiv; die Originale bleiben unberührt.
    public func exportDocument(_ document: ScanDocument, to url: URL, options: ExportOptions = .archive) async {
        guard exportProgress == nil else { return }
        guard !document.pages.isEmpty else { post(.warning, "Das Dokument hat noch keine Seiten."); return }
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
            post(.info, "PDF geschrieben: \(report.pageCount) Seite(n)"
                 + (options.ocr ? ", \(report.recognizedLines) Zeilen Text" : "") + " – \(url.path)")
            if !report.ocrFailures.isEmpty {
                let pages = report.ocrFailures.prefix(10).map(String.init).joined(separator: ", ")
                post(.warning, "Die Texterkennung schlug bei \(report.ocrFailures.count) Seite(n) fehl (\(pages)); sie stehen ohne Text im PDF.")
            }
        } catch {
            post(.error, "Der Export ist fehlgeschlagen: \(error.localizedDescription)")
        }
        exportProgress = nil
    }

    /// Lädt Scans und Dokumente des Archivs, einmal. Unabhängig vom Scanner: Auch ohne ihn lässt sich ein gespeichertes
    /// Dokument ansehen und als PDF ausgeben. Die Oberfläche ruft es beim Start vor dem Verbinden auf.
    public func loadArchive() async {
        guard !hasLoadedScans else { return }
        hasLoadedScans = true
        await loadExistingScans()
        await loadSavedDocuments()
    }

    /// Liest die gespeicherten Dokumente aus dem Archiv. Ein unlesbares Dokument wird gemeldet und übersprungen.
    private func loadSavedDocuments() async {
        let store = self.store
        let loaded: [ScanDocument] = await Task.detached { (try? store.allDocuments()) ?? [] }.value
        savedDocuments = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    /// Hält die Liste der gespeicherten Dokumente aktuell, wenn die laufende Serie gespeichert wird.
    private func updateSavedDocuments(with document: ScanDocument) {
        savedDocuments.removeAll { $0.id == document.id }
        savedDocuments.insert(document, at: 0)
        savedDocuments.sort { $0.createdAt > $1.createdAt }
    }

    private func appendToSeries(scanID: UUID) {
        guard var document = series else { return }
        if seriesIsBook {
            document.append(DocumentPage(scanID: scanID, region: .left))
            document.append(DocumentPage(scanID: scanID, region: .right))
        } else {
            document.append(DocumentPage(scanID: scanID))
        }
        commit(document)
    }

    /// Übernimmt die Korrekturen eines Scans in die zugehörige Seite der Serie, denn die Seite trägt sie selbst.
    private func mirrorToSeries(_ item: ScanItem) {
        guard var document = shownDocument else { return }
        var changed = false
        for page in document.pages where page.scanID == item.id && page.region == .whole && page.corrections != item.corrections {
            document.updateCorrections(pageID: page.id) { $0 = item.corrections }
            changed = true
        }
        if changed { commit(document) }
    }

    /// Speichert ein Dokument und hält die Anzeige aktuell: die laufende Serie, das geöffnete Dokument und die Liste.
    private func commit(_ document: ScanDocument) {
        do {
            try store.saveDocument(document)
            if series?.id == document.id { series = document }
            else if openedDocument?.id == document.id { openedDocument = document }
            updateSavedDocuments(with: document)
        } catch {
            post(.error, "Das Dokument konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    // MARK: Volle Auflösung

    /// Das Original eines Scans in voller Auflösung mit den aktuellen Korrekturen, für den Zoom. Die Ansichten in der Liste
    /// sind verkleinert und würden beim Hineinzoomen unscharf. Bei einer Buchseite gelten deren Korrekturen und ihr Ausschnitt.
    /// `nil`, wenn das Original nicht lesbar ist.
    public func fullResolutionImage(scanID: UUID, pageID: UUID? = nil) async -> CGImage? {
        let corrections: Corrections
        if let pageID, let page = shownDocument?.page(id: pageID) {
            corrections = PageGeometry.effectiveCorrections(for: page)
        } else if let item = scans.first(where: { $0.id == scanID }) {
            corrections = item.corrections
        } else {
            return nil
        }
        let key = "\(scanID.uuidString)/\(pageID?.uuidString ?? "-")"
        if let cached = fullResolutionCache.first(where: { $0.key == key && $0.corrections == corrections }) { return cached.image }

        let store = self.store
        let image: CGImage? = await Task.detached {
            guard let record = try? store.load(id: scanID),
                  let source = CGImageSourceCreateWithURL(store.originalURL(for: record) as CFURL, nil),
                  let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return CorrectionRenderer.render(original, corrections: corrections)
        }.value
        guard let image else { return nil }
        fullResolutionCache.removeAll { $0.key == key }
        fullResolutionCache.append((key, corrections, image))
        if fullResolutionCache.count > 2 { fullResolutionCache.removeFirst(fullResolutionCache.count - 2) }
        return image
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
        shownDocument?.pages.contains { $0.scanID == id && $0.region != .whole } ?? false
    }

    /// Die Seiten eines Scans in der Reihenfolge des Dokuments.
    public func pages(of scanID: UUID) -> [DocumentPage] {
        shownDocument?.pages.filter { $0.scanID == scanID } ?? []
    }

    /// `force` verwirft auch manuelle Änderungen, sonst gelten sie vor der Automatik.
    private func analyzeBookScan(id: UUID, image: CGImage, force: Bool = false) async {
        analyzing.insert(id)
        let analyzeBook = self.analyzeBook
        let result = await Task.detached { analyzeBook(image) }.value
        analyzing.remove(id)
        guard var document = shownDocument else { return }
        for page in document.pages where page.scanID == id {
            let corrections = page.region == .left ? result.left : result.right
            // Hat der Nutzer die Seite schon angefasst, gilt das und nicht die Automatik.
            guard force || page.corrections.revision == 0 else { continue }
            document.updateCorrections(pageID: page.id) { $0 = corrections }
        }
        commit(document)
        if let index = scans.firstIndex(where: { $0.id == id }) { scans[index].warnings = result.warnings }
        for warning in result.warnings { post(.warning, warning, scanID: id, asMessage: false) }
        refreshPagePreviews(scanID: id)
    }

    /// Ändert die Korrekturen einer Buchseite, speichert das Dokument und rendert die Seitenansicht neu.
    public func updatePageCorrections(pageID: UUID, _ change: (inout Corrections) -> Void) {
        guard var document = shownDocument, let page = document.page(id: pageID) else { return }
        document.updateCorrections(pageID: pageID, change)
        commit(document)
        refreshPagePreviews(scanID: page.scanID)
    }

    public func setPageRotation(pageID: UUID, degrees: Double) { updatePageCorrections(pageID: pageID) { $0.setRotation(degrees: degrees) } }
    public func setPageCropEnabled(pageID: UUID, _ on: Bool) { updatePageCorrections(pageID: pageID) { $0.setCropEnabled(on) } }
    public func setPageHandRemovalEnabled(pageID: UUID, _ on: Bool) { updatePageCorrections(pageID: pageID) { $0.setHandRemovalEnabled(on) } }

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
                guard let current = shownDocument?.page(id: id), pages.first(where: { $0.id == id })?.corrections == current.corrections else { continue }
                pagePreviews[id] = preview
            }
        }
    }

    private func apply(_ corrections: Corrections, warnings: [String], at index: Int) {
        scans[index].corrections = corrections
        scans[index].warnings = warnings
        for warning in warnings { post(.warning, warning, scanID: scans[index].id, asMessage: false) }
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
    public func setHandRemovalEnabled(id: UUID, _ on: Bool) { updateCorrections(id: id) { $0.setHandRemovalEnabled(on) } }
    public func setCorrectionsEnabled(id: UUID, _ on: Bool) { updateCorrections(id: id) { $0.setEnabled(on) } }

    private func persistAndRender(index: Int) {
        let item = scans[index]
        do {
            try store.saveCorrections(item.corrections, for: item.id)
        } catch {
            post(.error, "Die Korrekturen konnten nicht gespeichert werden: \(error.localizedDescription)")
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
