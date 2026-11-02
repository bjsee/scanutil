import Foundation

public enum ScannerError: Error, Equatable, LocalizedError {
    case deviceNotFound
    case cameraAccessDenied
    case formatUnavailable(ScanFormat)
    case timeout
    case controlFailed(name: String, code: Int)
    case encodingFailed
    case deviceBusy

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "Der Scanner wurde nicht gefunden. Ist er angeschlossen und eingeschaltet?"
        case .cameraAccessDenied:
            "Der Kamerazugriff ist verweigert. Bitte in den Systemeinstellungen unter Datenschutz und Sicherheit freigeben."
        case .formatUnavailable(let format):
            "Das Format \(format) wird vom Scanner nicht angeboten."
        case .timeout:
            "Der Scanner hat kein Bild geliefert. Läuft noch die CZUR-Software und belegt die Kamera?"
        case .controlFailed(let name, let code):
            "Die Einstellung \(name) konnte nicht geändert werden (Code \(code))."
        case .encodingFailed:
            "Das Bild konnte nicht kodiert werden."
        case .deviceBusy:
            "Es läuft bereits eine Aufnahme."
        }
    }
}
