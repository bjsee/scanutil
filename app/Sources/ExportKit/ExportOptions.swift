import Foundation

/// Einstellungen für den PDF-Export.
public struct ExportOptions: Equatable, Sendable {
    /// Auflösung, mit der die Vorlage aufgenommen wurde. Daraus folgt die Seitengröße im PDF.
    /// Der Scanner liefert keine Angabe zur wirklichen Größe, deshalb ist das eine Annahme des Anwenders.
    public var dpi: Double
    /// Längste Bildkante in Pixeln, oder `nil` für volle Auflösung. Beim Verkleinern sinkt die Auflösung mit,
    /// die Seite behält ihre Größe im PDF.
    public var maxLongSide: Int?
    /// JPEG-Qualität von 0 bis 1.
    public var jpegQuality: Double
    /// Texterkennung: legt den erkannten Text unsichtbar über das Bild, damit das PDF durchsuchbar ist.
    /// Kostet je Seite etwa 1,5 s und läuft nur, wenn es eingeschaltet ist.
    public var ocr: Bool
    /// Sprachen der Texterkennung in der Schreibweise von Vision, etwa `de-DE`.
    public var ocrLanguages: [String]

    /// Längste Bildkante, auf der die Texterkennung arbeitet. Größer bringt nur Zeit.
    static let ocrMaxLongSide = 3000

    public init(dpi: Double = 300, maxLongSide: Int? = nil, jpegQuality: Double = 0.85,
                ocr: Bool = false, ocrLanguages: [String] = ["de-DE"]) {
        self.dpi = dpi
        self.maxLongSide = maxLongSide
        self.jpegQuality = jpegQuality
        self.ocr = ocr
        self.ocrLanguages = ocrLanguages
    }

    /// Volle Auflösung, hohe Qualität.
    public static let archive = ExportOptions(dpi: 300, maxLongSide: nil, jpegQuality: 0.9)
    /// Klein genug zum Verschicken und für die Webseite.
    public static let web = ExportOptions(dpi: 300, maxLongSide: 2000, jpegQuality: 0.7)
}

/// Was beim Export geschehen ist. Ein Fehler der Texterkennung verwirft das PDF nicht, er steht hier.
public struct ExportReport: Equatable, Sendable {
    public let pageCount: Int
    /// Seitennummern (ab 1), deren Texterkennung fehlschlug. Die Seiten stehen ohne Textebene im PDF.
    public let ocrFailures: [Int]
    /// Zeilen erkannten Textes über alle Seiten.
    public let recognizedLines: Int

    public init(pageCount: Int, ocrFailures: [Int], recognizedLines: Int) {
        self.pageCount = pageCount
        self.ocrFailures = ocrFailures
        self.recognizedLines = recognizedLines
    }
}

public enum ExportError: Error, Equatable, LocalizedError {
    case emptyDocument
    case originalUnreadable(String)
    case renderFailed(pageNumber: Int)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyDocument: "Das Dokument hat keine Seiten."
        case .originalUnreadable(let path): "Das Original \(path) konnte nicht gelesen werden."
        case .renderFailed(let n): "Seite \(n) konnte nicht berechnet werden."
        case .writeFailed(let what): "Das PDF konnte nicht geschrieben werden: \(what)"
        }
    }
}
