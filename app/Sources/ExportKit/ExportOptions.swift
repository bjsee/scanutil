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

    public init(dpi: Double = 300, maxLongSide: Int? = nil, jpegQuality: Double = 0.85) {
        self.dpi = dpi
        self.maxLongSide = maxLongSide
        self.jpegQuality = jpegQuality
    }

    /// Volle Auflösung, hohe Qualität.
    public static let archive = ExportOptions(dpi: 300, maxLongSide: nil, jpegQuality: 0.9)
    /// Klein genug zum Verschicken und für die Webseite.
    public static let web = ExportOptions(dpi: 300, maxLongSide: 2000, jpegQuality: 0.7)
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
