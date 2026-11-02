import Foundation

/// Austauschbare Schnittstelle zum Scanner. Alles, was die Anwendung vom Gerät braucht.
/// Umsetzungen: `ET24Scanner` (echte Hardware) und `MockScanner` (Tests ohne Gerät).
public protocol ScannerPort: Sendable {
    /// Prüft, ob ein Gerät da ist, und liefert seine Angaben.
    func connect() async throws -> DeviceInfo

    /// Aufnahmeformate, die das Gerät anbietet, absteigend nach Pixelzahl.
    func availableFormats() async throws -> [ScanFormat]

    /// Öffnet eine dauerhafte Sitzung im Aufnahmeformat.
    ///
    /// Die Sitzung läuft, bis sie geschlossen wird. Vorschau und Aufnahme kommen aus demselben Bilderstrom,
    /// deshalb entfällt beim Auslösen jeder Wechsel von Format oder Sitzung.
    /// Die Einstellungen gelten für die ganze Sitzung und werden beim Schließen zurückgesetzt.
    func openSession(format: ScanFormat, settings: CaptureSettings) async throws -> any ScanSession
}

/// Eine laufende Verbindung zum Scanner.
public protocol ScanSession: Sendable {
    var device: DeviceInfo { get }
    var format: ScanFormat { get }

    /// Laufender Bilderstrom für die Live-Vorschau, verkleinert. Es darf nur ein Verbraucher lesen.
    var previewFrames: AsyncStream<PreviewFrame> { get }

    /// Nimmt das nächste Bild des Stroms in voller Auflösung als Original auf.
    func capture() async throws -> Capture

    /// Beendet die Sitzung und setzt die Einstellungen zurück. Mehrfaches Schließen ist harmlos.
    func close() async
}
