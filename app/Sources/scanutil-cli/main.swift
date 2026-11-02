import ArchiveKit
import CoreGraphics
import ExportKit
import Foundation
import ImageIO
import ImagingKit
import UniformTypeIdentifiers
import ScannerKit

// Kleines Werkzeug für den Durchstich: Formate anzeigen, aufnehmen, Archiv prüfen.
// scanutil-cli formats
// scanutil-cli capture <Archivordner> [--format BxH] [--sharpness N] [--mock]
// scanutil-cli verify <Archivordner>
// scanutil-cli export <Archivordner> <ziel.pdf> [--document ID] [--title T] [--preset archive|web] [--dpi N] [--auto] [--book]

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
guard let command = args.first else { fail("Aufruf: scanutil-cli formats | capture <Archivordner> | verify <Archivordner> | export <Archivordner> <ziel.pdf>") }

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

    case "analyze":
        // scanutil-cli analyze <bild.png> [--out korrigiert.png]
        guard args.count >= 2 else { fail("Bilddatei fehlt") }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Bild nicht lesbar") }
        let t0 = ContinuousClock.now
        let analysis = ImageAnalyzer.analyze(image)
        let t1 = ContinuousClock.now
        let corrections = ImageAnalyzer.corrections(from: analysis)
        print("Bild \(image.width)x\(image.height), Analyse \(t1 - t0)")
        if let d = analysis.detection {
            print(String(format: "Dokument: Plausibilität %.2f, Vision-Konfidenz %.2f", d.plausibility, d.reportedConfidence))
        } else { print("Dokument: nicht erkannt") }
        if let k = analysis.skew {
            print(String(format: "Schräglage: %+.2f° (Uhrzeigersinn), Sicherheit %.2f, Kontrast %.1f, Spitzenverhältnis %.2f", k.degrees, k.confidence, k.contrast, k.peakRatio))
        } else { print("Schräglage: nicht messbar") }
        print("Zuschnitt aktiv: \(corrections.crop.enabled), Drehung aktiv: \(corrections.rotation.enabled), Prüfung nötig: \(corrections.needsReview)")
        for w in analysis.warnings { print("  Hinweis: \(w)") }
        if let out = option("--out", in: args) {
            guard let rendered = CorrectionRenderer.render(image, corrections: corrections),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("Rendern fehlgeschlagen") }
            CGImageDestinationAddImage(dest, rendered, nil)
            CGImageDestinationFinalize(dest)
            print("korrigiert: \(out) (\(rendered.width)x\(rendered.height))")
        }

    case "export":
        guard args.count >= 3 else { fail("Aufruf: export <Archivordner> <ziel.pdf> [--document ID] [--title T] [--preset archive|web] [--dpi N] [--auto] [--book]") }
        let store = ArchiveStore(root: URL(fileURLWithPath: args[1], isDirectory: true))
        let target = URL(fileURLWithPath: args[2])

        var options: ExportOptions
        switch option("--preset", in: args) ?? "archive" {
        case "archive": options = .archive
        case "web": options = .web
        case let other: fail("Unbekanntes Preset: \(other) (archive oder web)")
        }
        if let dpi = option("--dpi", in: args) {
            guard let value = Double(dpi), value > 0 else { fail("--dpi braucht eine positive Zahl") }
            options.dpi = value
        }

        var document: ScanDocument
        if let id = option("--document", in: args) {
            guard let uuid = UUID(uuidString: id) else { fail("--document braucht eine UUID") }
            document = try store.loadDocument(id: uuid)
        } else {
            // Ohne Dokument: alle Scans in der Reihenfolge der Aufnahme, ungespeichert.
            var ad = ScanDocument(title: option("--title", in: args) ?? target.deletingPathExtension().lastPathComponent)
            let book = args.contains("--book")
            for record in try store.allRecords() {
                var corrections = try store.corrections(for: record.id) ?? .none
                var pageCorrections: [Corrections] = [corrections, corrections]
                if args.contains("--auto"),
                   // Die Analyse braucht das Original; bei 24 MP dauert sie spürbar.
                   let source = CGImageSourceCreateWithURL(store.originalURL(for: record) as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    if book {
                        let analysis = BookAnalyzer.analyze(image)
                        let pages = BookAnalyzer.corrections(from: analysis)
                        pageCorrections = [pages.left, pages.right]
                        for w in analysis.warnings { FileHandle.standardError.write(Data("\(record.id.uuidString.prefix(8)): \(w)\n".utf8)) }
                    } else if corrections == .none || corrections.revision == 0 {
                        corrections = ImageAnalyzer.corrections(from: ImageAnalyzer.analyze(image))
                        pageCorrections = [corrections, corrections]
                    }
                }
                if book {
                    ad.append(DocumentPage(scanID: record.id, region: .left, corrections: pageCorrections[0]))
                    ad.append(DocumentPage(scanID: record.id, region: .right, corrections: pageCorrections[1]))
                } else {
                    ad.append(DocumentPage(scanID: record.id, region: .whole, corrections: corrections))
                }
            }
            document = ad
        }
        guard !document.pages.isEmpty else { fail("Das Archiv enthält keine Scans.") }
        if let title = option("--title", in: args) { document.title = title }
        try PDFExporter(store: store).export(document, to: target, options: options) { done, total in
            print("\r\(done)/\(total)", terminator: "")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        print("\n\(document.pages.count) Seiten, \(String(format: "%.1f", Double(size) / 1_000_000)) MB: \(target.path)")

    default:
        fail("Unbekannter Befehl: \(command)")
    }
} catch {
    fail("Fehler: \(error.localizedDescription)")
}
