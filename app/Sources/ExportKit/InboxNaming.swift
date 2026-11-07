import Foundation

/// Dateinamen der Schnellablage: „2611 Tierarztpraxis.pdf“, also Jahr und Monat zweistellig, ein Leerzeichen, die Beschreibung.
public enum InboxNaming {
    /// Längste Beschreibung in Zeichen. Längeres bringt nichts im Dateinamen.
    public static let maxDescriptionLength = 60

    /// „2611“ für November 2026.
    public static func prefix(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%02d%02d", (parts.year ?? 0) % 100, parts.month ?? 0)
    }

    /// Eine brauchbare Beschreibung für einen Dateinamen: ohne Pfadtrenner, Doppelpunkt, Anführungszeichen und Zeilenumbrüche,
    /// Leerräume zusammengezogen, nicht länger als `maxDescriptionLength`, ohne Punkt am Anfang oder Ende.
    public static func cleanedDescription(_ raw: String) -> String {
        var text = raw
        for bad in ["/", ":", "\\", "\"", "„", "“", "”", "'", "*", "?", "<", ">", "|"] { text = text.replacingOccurrences(of: bad, with: " ") }
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        while text.hasPrefix(".") { text.removeFirst() }
        while text.hasSuffix(".") { text.removeLast() }
        if text.count > maxDescriptionLength {
            var cut = String(text.prefix(maxDescriptionLength))
            // Lieber am Wortende kürzen.
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > maxDescriptionLength / 2 { cut = String(cut[..<space]) }
            text = cut
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Der Dateiname ohne Endung: „2611 Tierarztpraxis“. Ohne Beschreibung nur „2611 Dokument“.
    public static func fileStem(date: Date, description: String?, calendar: Calendar = .current) -> String {
        let cleaned = cleanedDescription(description ?? "")
        return prefix(for: date, calendar: calendar) + " " + (cleaned.isEmpty ? "Dokument" : cleaned)
    }

    /// Ein Vorschlag aus dem erkannten Text ohne KI: die erste Zeile, die nach einem Namen aussieht (Buchstaben, kein Datum, keine
    /// Zahlenkolonne), auf höchstens vier Wörter gekürzt. `nil`, wenn nichts Brauchbares dabei ist.
    /// - Parameter lines: die Zeilen von oben nach unten.
    public static func heuristicDescription(from lines: [String]) -> String? {
        for line in lines.prefix(12) {
            let cleaned = cleanedDescription(line)
            let letters = cleaned.filter(\.isLetter).count
            guard letters >= 4, Double(letters) >= Double(cleaned.count) * 0.6 else { continue }
            let words = cleaned.split(separator: " ").prefix(4).joined(separator: " ")
            return cleanedDescription(words)
        }
        return nil
    }
}
