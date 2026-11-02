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
        let scanner: any ScannerPort = ProcessInfo.processInfo.environment["SCANUTIL_MOCK"] != nil ? MockScanner() : ET24Scanner()
        _model = State(initialValue: AppModel(scanner: scanner, store: ArchiveStore(root: URL(fileURLWithPath: path, isDirectory: true))))
    }

    var body: some Scene {
        WindowGroup("Scanutil") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
    }
}
