import ArchiveKit
import Foundation
import ScannerKit

// Kleines Werkzeug für den Durchstich: Formate anzeigen, aufnehmen, Archiv prüfen.
// scanutil-cli formats
// scanutil-cli capture <Archivordner> [--format BxH] [--sharpness N] [--mock]
// scanutil-cli verify <Archivordner>

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func parseFormat(_ text: String) -> ScanFormat? {
    let parts = text.lowercased().split(separator: "x").compactMap { Int($0) }
    return parts.count == 2 ? ScanFormat(width: parts[0], height: parts[1]) : nil
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("Aufruf: scanutil-cli formats | capture <Archivordner> | verify <Archivordner>") }

do {
    switch command {
    case "formats":
        let scanner = ET24Scanner()
        let device = try await scanner.connect()
        print("Gerät: \(device.name)")
        for f in try await scanner.availableFormats() { print("  \(f)  (\(String(format: "%.1f", f.megapixels)) MP)") }

    case "capture":
        guard args.count >= 2 else { fail("Archivordner fehlt") }
        let store = ArchiveStore(root: URL(fileURLWithPath: args[1], isDirectory: true))
        let scanner: any ScannerPort = args.contains("--mock") ? MockScanner() : ET24Scanner()
        let format = option("--format", in: args).flatMap(parseFormat) ?? (args.contains("--mock") ? ScanFormat(width: 640, height: 480) : ScanFormat(width: 5696, height: 4272))
        let sharpness = option("--sharpness", in: args).flatMap(Int.init) ?? CaptureSettings.archival.sharpness
        _ = try await scanner.connect()
        let count = option("--count", in: args).flatMap(Int.init) ?? 1
        let t0 = ContinuousClock.now
        let session = try await scanner.openSession(format: format, settings: CaptureSettings(sharpness: sharpness))
        print("Sitzung geöffnet in \(ContinuousClock.now - t0)")
        defer { Task { await session.close() } }
        for i in 1...count {
            let t1 = ContinuousClock.now
            let capture = try await session.capture()
            let t2 = ContinuousClock.now
            let record = try store.store(capture)
            let t3 = ContinuousClock.now
            print("[\(i)] \(record.original.width)x\(record.original.height), Aufnahme \(t2 - t1), Speichern \(t3 - t2), SHA-256 \(record.original.sha256.prefix(12))…")
        }
        await session.close()
        print("  Schärfe bei Aufnahme: \(sharpness.map(String.init) ?? "unverändert")")

    case "verify":
        guard args.count >= 2 else { fail("Archivordner fehlt") }
        let store = ArchiveStore(root: URL(fileURLWithPath: args[1], isDirectory: true))
        let records = try store.allRecords()
        var bad = 0
        for r in records {
            let ok = (try? store.verify(r)) ?? false
            if !ok { bad += 1 }
            print("\(ok ? "OK    " : "FEHLER") \(r.id.uuidString.lowercased())")
        }
        print("\(records.count) Einträge, \(bad) fehlerhaft")
        if bad > 0 { exit(2) }

    default:
        fail("Unbekannter Befehl: \(command)")
    }
} catch {
    fail("Fehler: \(error.localizedDescription)")
}
