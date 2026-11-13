import Foundation

/// Für welche Art Vorlage eine Serie aufgenommen wird. Das Profil legt Voreinstellungen fest; jede Einstellung bleibt je Seite änderbar.
///
/// Buch und Dokument sind Text auf Papier: Das Papier wird aufgehellt und die Schrift geschärft. Ein Foto hat kein „Papier“, das weiß
/// werden soll: Das Aufhellen würde Himmel und Hauttöne verschieben und helle Bildteile ausbrennen, das Schärfen Korn betonen.
public enum ScanProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case book, document, photo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .book: "Buch"
        case .document: "Dokument"
        case .photo: "Foto"
        }
    }

    /// Eine Zeile dazu für Hilfetexte.
    public var summary: String {
        switch self {
        case .book: "Doppelseiten, am Falz geteilt; Papier aufhellen"
        case .document: "Einzelne Seiten; Papier aufhellen"
        case .photo: "Einzelne Seiten; Farben bleiben, nichts wird aufgehellt oder nachgeschärft"
        }
    }

    /// Ob jede Aufnahme eine Doppelseite ist.
    public var isBook: Bool { self == .book }

    /// Ob das Papier aufgehellt und die Schrift geschärft wird.
    public var lightensPaper: Bool { self != .photo }

    /// JPEG-Qualität im PDF. Fotos behalten mehr, weil Verläufe und feine Zeichnung sonst leiden.
    public var jpegQuality: Double { self == .photo ? 0.95 : 0.85 }

    /// Passt die Korrekturen einer Aufnahme an das Profil an. Was der Nutzer von Hand eingestellt hat (`source == .manual`), bleibt.
    public func adjusted(_ corrections: Corrections) -> Corrections {
        var result = corrections
        if result.tone.source == .automatic { result.tone.enabled = lightensPaper }
        return result
    }
}
