import Foundation

/// Austauschbare Schnittstelle zum Scanner. Alles, was die Anwendung vom Gerät braucht.
/// Umsetzungen: `ET24Scanner` (echte Hardware) und `MockScanner` (Tests ohne Gerät).
public protocol ScannerPort: Sendable {
    /// Prüft, ob ein Gerät da ist, und liefert seine Angaben.
    func connect() async throws -> DeviceInfo

    /// Aufnahmeformate, die das Gerät anbietet, absteigend nach Pixelzahl.
    func availableFormats() async throws -> [ScanFormat]

    /// Laufender Bilderstrom für die Live-Vorschau in einem kleinen Format.
    /// Beenden des Stroms (Abbruch des Verbrauchers) gibt das Gerät wieder frei.
    /// Eine Aufnahme wartet kurz, bis der Strom das Gerät freigegeben hat.
    func previewFrames(format: ScanFormat) -> AsyncThrowingStream<PreviewFrame, Error>

    /// Löst eine Aufnahme aus. Die Einstellungen gelten nur für diese Aufnahme und werden danach zurückgesetzt.
    func capture(format: ScanFormat, settings: CaptureSettings) async throws -> Capture
}
