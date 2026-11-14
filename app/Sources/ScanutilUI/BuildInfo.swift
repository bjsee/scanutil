import Foundation

/// Welcher Stand der App läuft: der Zeitpunkt, an dem `scripts/bundle.sh` sie gebaut hat, und der Commit dazu. Beides steht in der
/// Info.plist der App (`ScanutilBuildTimestamp`, `ScanutilBuildCommit`). Ohne App-Bündel (etwa bei `swift run`) gibt es keinen Eintrag.
public enum BuildInfo {
    /// Die Rohform in der Info.plist: „2026-11-14 09:41:07“ (Ortszeit des Rechners, auf dem gebaut wurde).
    public static func timestamp(bundle: Bundle = .main) -> String? { bundle.object(forInfoDictionaryKey: "ScanutilBuildTimestamp") as? String }

    /// Der Commit, aus dem gebaut wurde; ein „+“ dahinter heißt: mit noch nicht committeten Änderungen.
    public static func commit(bundle: Bundle = .main) -> String? { bundle.object(forInfoDictionaryKey: "ScanutilBuildCommit") as? String }

    /// Für die Anzeige: „Version 14.11.2026 09:41“. Ohne Zeitstempel „Entwicklungsstand“; ein Wert in unbekannter Form wird unverändert gezeigt.
    public static func display(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Entwicklungsstand" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return "Version \(raw)" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "dd.MM.yyyy HH:mm"
        return "Version " + out.string(from: date)
    }

    /// Der Text der Anzeige in der Oberfläche.
    public static var displayText: String { display(timestamp()) }

    /// Der Hinweistext beim Daraufzeigen: Zeitpunkt auf die Sekunde und Commit.
    public static var detailText: String {
        var parts = [timestamp().map { "Gebaut am \($0)" } ?? "Nicht aus einem App-Bündel gestartet"]
        if let commit = commit() { parts.append("Commit \(commit)") }
        return parts.joined(separator: " · ")
    }
}
