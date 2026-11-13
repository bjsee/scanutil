import ArchiveKit
import CoreGraphics
import ExportKit
import Foundation
import ImageIO
import ImagingKit
import UniformTypeIdentifiers
import ScannerKit
import CUVC

// Kleines Werkzeug für den Durchstich: Formate anzeigen, aufnehmen, Archiv prüfen.
// scanutil-cli formats
// scanutil-cli capture <Archivordner> [--format BxH] [--sharpness N] [--mock]
// scanutil-cli verify <Archivordner>
// scanutil-cli export <Archivordner> <ziel.pdf> [--document ID] [--title T] [--preset archive|web] [--dpi N] [--auto] [--book] [--ocr] [--lang de-DE,en-US]

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

/// Zeichnet Rand (blau), Falz (rot) und die beiden Seiten (grün, orange) über ein verkleinertes Bild, zum Ansehen.
func drawBookOverlay(_ image: CGImage, _ analysis: BookAnalysis) -> CGImage? {
    let scale = min(1, 1600 / Double(max(image.width, image.height)))
    let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
    guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    func point(_ p: NormalizedPoint) -> CGPoint { CGPoint(x: p.x * Double(w), y: (1 - p.y) * Double(h)) }   // Bild y nach unten
    func path(_ q: Quad, _ color: CGColor, width: CGFloat = 3) {
        context.setStrokeColor(color); context.setLineWidth(width)
        context.move(to: point(q.topLeft)); context.addLine(to: point(q.topRight)); context.addLine(to: point(q.bottomRight))
        context.addLine(to: point(q.bottomLeft)); context.closePath(); context.strokePath()
    }
    if let o = analysis.outer { path(o.quad, CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1), width: 4) }
    path(analysis.leftQuad, CGColor(red: 0.1, green: 0.9, blue: 0.2, alpha: 1))
    path(analysis.rightQuad, CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1))
    if let g = analysis.gutter {
        context.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1)); context.setLineWidth(3)
        context.move(to: point(NormalizedPoint(x: g.xTop, y: 0))); context.addLine(to: point(NormalizedPoint(x: g.xBottom, y: 1)))
        context.strokePath()
    }
    return context.makeImage()
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

    case "hands":
        // scanutil-cli hands <scan.png> --out überlagerung.png [--cleaned bereinigt.png]
        // Zeigt, welche Fläche die Hand- und Markererkennung maskiert (rot), und schreibt auf Wunsch das bereinigte Bild.
        guard args.count >= 2 else { fail("Aufruf: scanutil-cli hands <scan.png> --out überlagerung.png [--cleaned bereinigt.png]") }
        let input = URL(fileURLWithPath: args[1])
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Bild nicht lesbar") }
        guard let detection = HandDetector.detect(in: image) else { print("Nichts erkannt."); break }
        let mask = detection.mask
        print("Erkannt: \(detection.regions) Fläche(n), \(detection.markers) Marker, Anteil \(String(format: "%.1f", mask.coverage * 100)) %")
        func write(_ image: CGImage, to path: String) {
            guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(d, image, nil); CGImageDestinationFinalize(d)
        }
        if let out = option("--out", in: args),
           let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.45))
            let cw = Double(image.width) / Double(mask.width), ch = Double(image.height) / Double(mask.height)
            for y in 0..<mask.height { for x in 0..<mask.width where mask.cells[y * mask.width + x] > 127 {
                context.fill(CGRect(x: Double(x) * cw, y: Double(image.height) - Double(y + 1) * ch, width: cw + 1, height: ch + 1))
            } }
            if let result = context.makeImage() { write(result, to: out) }
        }
        if let cleaned = option("--cleaned", in: args), let result = HandRemover.apply(to: image, mask: mask) { write(result, to: cleaned) }
    case "tone":
        // scanutil-cli tone <bild.png> --out hell.png: das Bild mit Papier aufhellen, zum Ansehen.
        guard args.count >= 2, let out = option("--out", in: args) else { fail("Aufruf: scanutil-cli tone <bild.png> --out hell.png") }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Bild nicht lesbar") }
        var corrections = Corrections()
        corrections.tone = ToneCorrection(enabled: true)
        guard let result = CorrectionRenderer.render(image, corrections: corrections),
              let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("Fehlgeschlagen") }
        CGImageDestinationAddImage(d, result, nil); CGImageDestinationFinalize(d)
    case "skew-strips":
        // scanutil-cli skew-strips <bild.png>   Schräglage jeder Buchseite insgesamt und je senkrechtem Streifen (Untersuchung der Wölbung)
        guard args.count >= 2, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Bild nicht lesbar") }
        let analysis = BookAnalyzer.analyze(image)
        if let outDir = option("--out", in: args) {
            let pair = BookAnalyzer.corrections(from: analysis)
            for (name, corr) in [("links", pair.left), ("rechts", pair.right)] {
                if let img = CorrectionRenderer.render(image, corrections: corr),
                   let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outDir + "/seite-\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
                }
            }
        }
        for (name, quad) in [("links", analysis.leftQuad), ("rechts", analysis.rightQuad)] {
            var c = Corrections(crop: CropCorrection(quad: quad, enabled: true)); c.enabled = true
            guard let page = CorrectionRenderer.render(image, corrections: c) else { continue }
            var line = String(format: "%@: ganz %.2f", name, SkewEstimator.estimate(page)?.degrees ?? .nan)
            let w = page.width, h = page.height
            for (a, b) in [(0.0, 0.25), (0.15, 0.4), (0.3, 0.55), (0.45, 0.7), (0.6, 0.85), (0.75, 1.0)] {
                if let strip = page.cropping(to: CGRect(x: Double(w) * a, y: 0, width: Double(w) * (b - a), height: Double(h))) {
                    line += String(format: " | %.1f–%.1f: %.2f", a, b, SkewEstimator.estimate(strip)?.degrees ?? .nan)
                }
            }
            line += " || Höhe"
            for (a, b) in [(0.0, 0.34), (0.33, 0.67), (0.66, 1.0), (0.0, 0.5), (0.5, 1.0)] {
                if let band = page.cropping(to: CGRect(x: 0, y: Double(h) * a, width: Double(w), height: Double(h) * (b - a))) {
                    line += String(format: " | %.2f–%.2f: %.2f", a, b, SkewEstimator.estimate(band)?.degrees ?? .nan)
                }
            }
            print(line)
        }
    case "usb-descriptor":
        // Gibt die Konfigurationsbeschreibung des Scanners als Hexzeichen aus, zur Untersuchung der UVC-Fähigkeiten.
        var bytes = [UInt8](repeating: 0, count: 4096)
        let length = cuvc_config_descriptor(&bytes, Int32(bytes.count))
        guard length > 0 else { fail("Beschreibung nicht lesbar (Code \(length))") }
        print(bytes.prefix(Int(length)).map { String(format: "%02x", $0) }.joined())
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
        // scanutil-cli analyze <bild.png> --book [--out ueberlagerung.png]   Doppelseite: Rand, Falz und Seiten einzeichnen
        guard args.count >= 2 else { fail("Bilddatei fehlt") }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Bild nicht lesbar") }
        if args.contains("--hands") {
            // Hände und Daumen: Maske magentafarben über das Bild legen, zum Ansehen.
            let t0 = ContinuousClock.now
            let outer = DocumentDetector.detect(in: image)
            let detection = HandDetector.detect(in: image, page: outer?.quad)
            print("Bild \(image.width)x\(image.height), Erkennung \(ContinuousClock.now - t0)")
            print(outer.map { String(format: "Seitenrand: Plausibilität %.2f", $0.plausibility) } ?? "Seitenrand: nicht erkannt")
            if let d = detection {
                print(String(format: "Hände: %d Flächen (davon %d Marker), %.1f %% des Bildes, Sicherheit %.2f", d.regions, d.markers, d.mask.coverage * 100, d.confidence))
            } else { print("Hände: keine erkannt") }
            if let out = option("--out", in: args) {
                let scale = min(1, 1600 / Double(max(image.width, image.height)))
                let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
                guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { fail("Überlagerung fehlgeschlagen") }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let mask = detection?.mask {
                    let provider = CGDataProvider(data: Data(mask.cells.map { $0 > 127 ? UInt8(160) : 0 }) as CFData)!
                    if let overlay = CGImage(width: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: mask.width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                             decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                        context.saveGState()
                        context.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: overlay)
                        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
                        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
                        context.restoreGState()
                    }
                }
                if let o = outer {
                    func pt(_ p: NormalizedPoint) -> CGPoint { CGPoint(x: p.x * Double(w), y: (1 - p.y) * Double(h)) }
                    context.setStrokeColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)); context.setLineWidth(3)
                    context.move(to: pt(o.quad.topLeft)); context.addLine(to: pt(o.quad.topRight)); context.addLine(to: pt(o.quad.bottomRight))
                    context.addLine(to: pt(o.quad.bottomLeft)); context.closePath(); context.strokePath()
                }
                guard let result = context.makeImage(),
                      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { fail("Überlagerung fehlgeschlagen") }
                CGImageDestinationAddImage(dest, result, nil)
                CGImageDestinationFinalize(dest)
                print("Überlagerung: \(out)")
            }
            if let clean = option("--clean", in: args), let mask = detection?.mask {
                // Das Bild ohne Hände, in voller Auflösung.
                let t1 = ContinuousClock.now
                guard let cleaned = HandRemover.apply(to: image, mask: mask),
                      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: clean) as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { fail("Entfernen fehlgeschlagen") }
                CGImageDestinationAddImage(dest, cleaned, nil)
                CGImageDestinationFinalize(dest)
                print("ohne Hände: \(clean) (\(cleaned.width)x\(cleaned.height)), Entfernen \(ContinuousClock.now - t1)")
            }
            break
        }
        if args.contains("--book") {
            let t0 = ContinuousClock.now
            let analysis = BookAnalyzer.analyze(image)
            print("Bild \(image.width)x\(image.height), Analyse \(ContinuousClock.now - t0)")
            if let o = analysis.outer {
                print(String(format: "Rand: Plausibilität %.2f, Vision-Konfidenz %.2f", o.plausibility, o.reportedConfidence))
                print("  Ecken: \(o.quad.topLeft) \(o.quad.topRight) \(o.quad.bottomRight) \(o.quad.bottomLeft)")
            } else { print("Rand: nicht erkannt oder verworfen") }
            if let g = analysis.gutter {
                print(String(format: "Falz: x oben %.3f, unten %.3f, Neigung %+.3f, Sicherheit %.2f", g.xTop, g.xBottom, g.slope, g.confidence))
            } else { print("Falz: nicht gefunden") }
            for (name, skew) in [("links", analysis.leftSkew), ("rechts", analysis.rightSkew)] {
                if let k = skew { print(String(format: "Schräglage %@: %+.2f°, Sicherheit %.2f", name, k.degrees, k.confidence)) }
                else { print("Schräglage \(name): nicht messbar") }
            }
            for w in analysis.warnings { print("  Hinweis: \(w)") }
            if let out = option("--out", in: args) {
                guard let overlay = drawBookOverlay(image, analysis),
                      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { fail("Überlagerung fehlgeschlagen") }
                CGImageDestinationAddImage(dest, overlay, nil)
                CGImageDestinationFinalize(dest)
                print("Überlagerung: \(out)")
            }
            if let folder = option("--pages", in: args) {
                // Die beiden Seiten so, wie der Export sie erzeugt: Korrekturen aus der Analyse, Ausschnitt je Seite.
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                let pages = BookAnalyzer.corrections(from: analysis)
                for (side, region, corrections) in [("links", PageRegion.left, pages.left), ("rechts", .right, pages.right)] {
                    let page = DocumentPage(scanID: UUID(), region: region, corrections: corrections)
                    let effective = PageGeometry.effectiveCorrections(for: page)
                    guard let rendered = CorrectionRenderer.render(image, corrections: effective),
                          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: folder).appendingPathComponent("\(side).png") as CFURL,
                                                                     UTType.png.identifier as CFString, 1, nil) else { fail("Seite \(side) fehlgeschlagen") }
                    CGImageDestinationAddImage(dest, rendered, nil)
                    CGImageDestinationFinalize(dest)
                    print("Seite \(side): \(rendered.width)x\(rendered.height), Zuschnitt aktiv: \(effective.crop.enabled), Drehung aktiv: \(effective.rotation.enabled) (\(String(format: "%+.2f", effective.rotation.degrees))°)")
                }
            }
            break
        }
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
        guard args.count >= 3 else { fail("Aufruf: export <Archivordner> <ziel.pdf> [--document ID] [--title T] [--preset archive|web] [--dpi N] [--auto] [--book] [--ocr] [--lang de-DE,en-US]") }
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

        if args.contains("--ocr") {
            options.ocr = true
            if let lang = option("--lang", in: args) { options.ocrLanguages = lang.split(separator: ",").map(String.init) }
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
        let report = try PDFExporter(store: store).export(document, to: target, options: options) { done, total in
            print("\r\(done)/\(total)", terminator: "")
        }
        if options.ocr {
            print("\nText: \(report.recognizedLines) Zeilen erkannt")
            if !report.ocrFailures.isEmpty { print("Texterkennung fehlgeschlagen bei Seite \(report.ocrFailures.map(String.init).joined(separator: ", "))") }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        print("\n\(document.pages.count) Seiten, \(String(format: "%.1f", Double(size) / 1_000_000)) MB: \(target.path)")

    default:
        fail("Unbekannter Befehl: \(command)")
    }
} catch {
    fail("Fehler: \(error.localizedDescription)")
}
