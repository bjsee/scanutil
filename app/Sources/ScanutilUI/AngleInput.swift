import Foundation

/// Ein Winkel aus einem Eingabefeld: „0“, „-1,5“, „+0.25“, „1,5°“. Komma und Punkt gelten beide als Dezimaltrenner.
public enum AngleInput {
    /// Größter Winkel, den die Drehung zulässt (wie der Regler im Editor).
    public static let limit = 15.0

    /// Der Winkel in Grad, auf ±15° begrenzt; `nil`, wenn die Eingabe keine Zahl ist.
    public static func parse(_ text: String) -> Double? {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        if cleaned.hasSuffix("°") { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return clamped(value)
    }

    public static func clamped(_ degrees: Double) -> Double { min(limit, max(-limit, degrees)) }

    /// Für die Anzeige mit Komma und Vorzeichen, etwa „+0,50°“.
    public static func text(_ degrees: Double) -> String {
        String(format: "%+.2f°", degrees).replacingOccurrences(of: ".", with: ",")
    }
}
