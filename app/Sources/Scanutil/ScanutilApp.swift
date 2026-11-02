import ArchiveKit
import ScannerKit
import ScanutilUI
import SwiftUI

@main
struct ScanutilApp: App {
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
        }
    }
}
