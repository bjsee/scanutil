import AppKit
import ArchiveKit
import ScannerKit
import ScanutilUI
import SwiftUI

/// Macht aus der Binärdatei ein reguläres Programm mit Tastaturfokus. Ohne das bekommt eine nicht gebündelte
/// App keine Tasteneingaben, sie landen im Terminal, aus dem sie gestartet wurde.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Schließt vor dem Beenden die Scanner-Sitzung, damit die Schärfe im Gerät wieder auf den Standardwert kommt.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.disconnect()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ScanutilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // Archiv standardmäßig unter Bilder; für Versuche per Umgebungsvariable umlenkbar.
        let path = ProcessInfo.processInfo.environment["SCANUTIL_ARCHIVE"]
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Scanutil-Archiv").path
        let scanner = Self.makeScanner(ProcessInfo.processInfo.environment["SCANUTIL_MOCK"])
        _model = State(initialValue: AppModel(scanner: scanner, store: ArchiveStore(root: URL(fileURLWithPath: path, isDirectory: true))))
    }

    /// `SCANUTIL_MOCK`: nicht gesetzt = echter Scanner, `document` = schiefe Textseite, `document-still` = dieselbe Seite mit
    /// stehender Vorschau (die Auto-Auslösung sieht Ruhe), `noise` = Rauschen (Automatik unsicher),
    /// jeder andere Wert = Graustufenverlauf. Für Entwicklung und die Oberflächentests.
    private static func makeScanner(_ mode: String?) -> any ScannerPort {
        switch mode {
        case nil: ET24Scanner()
        case "document": SyntheticPage.scanner(delivering: SyntheticPage.textPage(width: 1600, height: 1600, tiltCounterClockwise: 6, background: 10, raggedEdges: 30))
        case "document-still": SyntheticPage.scanner(delivering: SyntheticPage.textPage(width: 1600, height: 1600, tiltCounterClockwise: 6, background: 10, raggedEdges: 30), stillPreview: true)
        case "noise": SyntheticPage.scanner(delivering: SyntheticPage.noise(width: 1200, height: 1200))
        default: MockScanner()
        }
    }

    var body: some Scene {
        WindowGroup("Scanutil") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
    }
}
