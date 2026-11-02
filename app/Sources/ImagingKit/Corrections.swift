import Foundation

/// Punkt in normierten Bildkoordinaten: x und y von 0 bis 1, Ursprung oben links, y nach unten.
/// Normiert, damit dieselben Korrekturen für jede Auflösung gelten (Vorschau, Original).
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Vier Ecken des Dokuments im Originalbild.
public struct Quad: Codable, Equatable, Sendable {
    public var topLeft: NormalizedPoint
    public var topRight: NormalizedPoint
    public var bottomRight: NormalizedPoint
    public var bottomLeft: NormalizedPoint

    public init(topLeft: NormalizedPoint, topRight: NormalizedPoint, bottomRight: NormalizedPoint, bottomLeft: NormalizedPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Das ganze Bild.
    public static let full = Quad(
        topLeft: .init(x: 0, y: 0), topRight: .init(x: 1, y: 0),
        bottomRight: .init(x: 1, y: 1), bottomLeft: .init(x: 0, y: 1)
    )
}

/// Woher ein Wert stammt. Eine manuelle Eingabe überschreibt jede automatische Erkennung.
public enum CorrectionSource: String, Codable, Sendable {
    case automatic
    case manual
}

/// Zuschnitt auf das Dokument mit Perspektivkorrektur.
public struct CropCorrection: Codable, Equatable, Sendable {
    public var quad: Quad?
    public var enabled: Bool
    public var source: CorrectionSource
    /// Sicherheit der automatischen Erkennung von 0 bis 1, bei manueller Eingabe nicht gesetzt.
    public var confidence: Double?

    public init(quad: Quad? = nil, enabled: Bool = false, source: CorrectionSource = .automatic, confidence: Double? = nil) {
        self.quad = quad
        self.enabled = enabled
        self.source = source
        self.confidence = confidence
    }
}

/// Drehung zur Begradigung.
public struct RotationCorrection: Codable, Equatable, Sendable {
    /// Drehung des Bildes im Uhrzeigersinn in Grad. Ein nach rechts ansteigender Text braucht einen positiven Wert.
    public var degrees: Double
    public var enabled: Bool
    public var source: CorrectionSource
    public var confidence: Double?

    public init(degrees: Double = 0, enabled: Bool = false, source: CorrectionSource = .automatic, confidence: Double? = nil) {
        self.degrees = degrees
        self.enabled = enabled
        self.source = source
        self.confidence = confidence
    }
}

/// Alle Korrekturen zu einem Original. Das Original bleibt unverändert, daraus entsteht jederzeit reproduzierbar das korrigierte Bild.
public struct Corrections: Codable, Equatable, Sendable {
    /// Ab dieser Sicherheit wird eine automatische Erkennung angewendet, darunter nur vorgeschlagen und zur Prüfung markiert.
    public static let defaultConfidenceThreshold = 0.6

    public var version: Int = 1
    /// Hauptschalter: aus bedeutet, das Original wird unverändert angezeigt und exportiert.
    public var enabled: Bool
    public var crop: CropCorrection
    public var rotation: RotationCorrection
    /// Hochgezählt bei jeder Änderung.
    public var revision: Int

    public init(enabled: Bool = true, crop: CropCorrection = .init(), rotation: RotationCorrection = .init(), revision: Int = 0) {
        self.enabled = enabled
        self.crop = crop
        self.rotation = rotation
        self.revision = revision
    }

    public static let none = Corrections()

    /// Eine automatische Erkennung liegt vor, ist aber nicht sicher genug, um sie anzuwenden.
    public var needsReview: Bool {
        (crop.source == .automatic && !crop.enabled && crop.quad != nil)
            || (rotation.source == .automatic && !rotation.enabled && rotation.confidence != nil)
    }

    /// Setzt den Drehwinkel von Hand. Ab dann gilt er als manuell und ist aktiv.
    public mutating func setRotation(degrees: Double) {
        rotation = RotationCorrection(degrees: degrees, enabled: true, source: .manual, confidence: nil)
        revision += 1
    }

    public mutating func setCrop(_ quad: Quad) {
        crop = CropCorrection(quad: quad, enabled: true, source: .manual, confidence: nil)
        revision += 1
    }

    public mutating func setCropEnabled(_ on: Bool) {
        crop.enabled = on
        crop.source = .manual
        revision += 1
    }

    public mutating func setRotationEnabled(_ on: Bool) {
        rotation.enabled = on
        rotation.source = .manual
        revision += 1
    }

    public mutating func setEnabled(_ on: Bool) {
        enabled = on
        revision += 1
    }
}
