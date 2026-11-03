import Foundation

/// Was die automatische Analyse über eine Seite wusste: die Rohwerte hinter den Korrekturen. Sie werden mit dem Dokument
/// gespeichert, damit sich später beurteilen lässt, wo die Automatik unsicher war, auch nach einem Neustart. Eine Warnung
/// allein ginge sonst mit dem Protokoll verloren.
public struct PageAnalysis: Codable, Equatable, Sendable {
    /// Ob Rand der Seite (bei einer Doppelseite: des Buchs) erkannt und plausibel war. Ohne ihn besteht ein Zuschnitt aus Bildhälften.
    public var outerDetected: Bool
    /// Plausibilität des erkannten Randes von 0 bis 1.
    public var outerPlausibility: Double?
    /// Nur bei Doppelseiten: Sicherheit des Falzes von 0 bis 1, `nil` heißt: kein Falz gefunden, in der Mitte geteilt.
    public var gutterConfidence: Double?
    public var isSpread: Bool
    /// Anteil des Bildes, den erkannte Hände, Daumen und Marker bedecken, von 0 bis 1.
    public var handCoverage: Double?
    public var handMarkers: Int?
    /// Die Warnungen der Analyse im Wortlaut.
    public var warnings: [String]

    public init(outerDetected: Bool, outerPlausibility: Double? = nil, gutterConfidence: Double? = nil, isSpread: Bool = false,
                handCoverage: Double? = nil, handMarkers: Int? = nil, warnings: [String] = []) {
        self.outerDetected = outerDetected
        self.outerPlausibility = outerPlausibility
        self.gutterConfidence = gutterConfidence
        self.isSpread = isSpread
        self.handCoverage = handCoverage
        self.handMarkers = handMarkers
        self.warnings = warnings
    }
}

extension ImageAnalyzer {
    /// Die Zusammenfassung einer Analyse einer Einzelseite.
    public static func pageAnalysis(from analysis: Analysis) -> PageAnalysis {
        PageAnalysis(outerDetected: analysis.detection != nil, outerPlausibility: analysis.detection?.plausibility,
                     handCoverage: analysis.hands?.mask.coverage, handMarkers: analysis.hands?.markers, warnings: analysis.warnings)
    }
}

extension BookAnalyzer {
    /// Die Zusammenfassung einer Analyse einer Doppelseite. Beide Seiten tragen dieselbe: Rand, Falz und Hände gehören zur Aufnahme.
    public static func pageAnalysis(from analysis: BookAnalysis) -> PageAnalysis {
        PageAnalysis(outerDetected: analysis.outer != nil, outerPlausibility: analysis.outer?.plausibility,
                     gutterConfidence: analysis.gutter?.confidence, isSpread: true,
                     handCoverage: analysis.hands?.mask.coverage, handMarkers: analysis.hands?.markers, warnings: analysis.warnings)
    }
}
