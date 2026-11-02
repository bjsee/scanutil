import Foundation

/// Entscheidet im Serienmodus, wann eine Aufnahme ausgelöst wird: wenn eine Seite gewechselt wurde und danach Ruhe herrscht.
///
/// Gespeist wird sie mit den Vorschaubildern und ihrem Zeitstempel. Sie kennt weder Kamera noch Uhr und lässt sich
/// deshalb mit künstlichen Bildfolgen prüfen.
///
/// Ablauf: Bewegung → Ruhe über `calmDuration` → Auslösung → gesperrt, bis wieder Bewegung gesehen wurde.
/// Die Sperre verhindert, dass dieselbe ruhende Seite endlos aufgenommen wird.
/// Ist die Seite nach der Bewegung unverändert (die Hand fuhr nur durchs Bild), löst sie nicht aus.
public struct AutoTrigger: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Mittlere Änderung zum Vorbild, ab der es als Bewegung gilt.
        public var motionThreshold: Double = 0.02
        /// Wie lange das Bild ruhig sein muss, in Sekunden.
        public var calmDuration: TimeInterval = 0.8
        /// Anteil geänderter Zellen gegenüber der letzten Aufnahme, ab dem es eine neue Seite ist.
        public var newPageThreshold: Double = 0.01
        /// Ob gleich nach dem Start ausgelöst wird, sobald Ruhe herrscht, ohne vorher Bewegung zu verlangen.
        public var fireOnStart: Bool = true

        public init() {}
    }

    public enum Phase: Equatable, Sendable {
        /// Gesperrt, bis Bewegung kommt: nach einer Auslösung oder einer übersprungenen Dublette.
        case waitingForMotion
        case moving
        /// Ruhig seit `seconds`, ausgelöst wird bei `Configuration.calmDuration`.
        case calm(seconds: TimeInterval)
    }

    public enum Event: Equatable, Sendable {
        case none
        /// Jetzt aufnehmen.
        case fire
        /// Ruhe nach Bewegung, aber die Seite gleicht der letzten Aufnahme. Es wird nicht ausgelöst.
        case skippedDuplicate
    }

    public var configuration: Configuration
    public private(set) var phase: Phase

    private var previous: FrameSignature?
    /// Bild, mit dem die Ruhe verglichen wird: schleichende Bewegung zählt so nicht als Ruhe.
    private var anchor: FrameSignature?
    private var calmSince: TimeInterval?
    private var lastCaptured: FrameSignature?
    private var armed: Bool

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        armed = configuration.fireOnStart
        phase = configuration.fireOnStart ? .moving : .waitingForMotion
    }

    /// Verwirft den Zustand, etwa wenn die Sitzung neu beginnt.
    public mutating func reset() {
        self = AutoTrigger(configuration: configuration)
    }

    /// Meldet ein neues Vorschaubild. Gibt `.fire` zurück, wenn jetzt aufgenommen werden soll.
    /// `time` ist ein beliebiger, aufsteigender Zeitstempel in Sekunden.
    public mutating func feed(_ frame: FrameSignature, at time: TimeInterval) -> Event {
        defer { previous = frame }
        guard let previous else {
            anchor = frame
            calmSince = time
            return .none
        }

        let moved = frame.meanDifference(to: previous) > configuration.motionThreshold
        let drifted = anchor.map { frame.meanDifference(to: $0) > configuration.motionThreshold } ?? false

        if moved || drifted {
            // Bewegung: Ruhe beginnt von vorn, und eine neue Auslösung ist wieder erlaubt.
            armed = true
            anchor = frame
            calmSince = nil
            phase = .moving
            return .none
        }

        let since = calmSince ?? time
        calmSince = since
        let calm = time - since
        phase = armed ? .calm(seconds: calm) : .waitingForMotion
        guard armed, calm >= configuration.calmDuration else { return .none }

        armed = false
        phase = .waitingForMotion
        if let last = lastCaptured, frame.changedFraction(to: last) < configuration.newPageThreshold {
            return .skippedDuplicate
        }
        lastCaptured = frame
        return .fire
    }

    /// Merkt sich, dass von Hand aufgenommen wurde, damit die Ruhe danach nicht dieselbe Seite nochmals auslöst.
    public mutating func noteManualCapture(of frame: FrameSignature) {
        lastCaptured = frame
        armed = false
        phase = .waitingForMotion
    }
}
