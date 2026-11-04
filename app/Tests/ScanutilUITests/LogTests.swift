import ArchiveKit
import CoreGraphics
import ExportKit
import Foundation
import ImageIO
import ImagingKit
import ScannerKit
import SwiftUI
import Testing
@testable import ScanutilUI

@MainActor
@Suite("Protokoll")
struct LogTests {
    nonisolated private static func analysis(warnings: [String]) -> @Sendable (CGImage) -> AnalysisResult {
        { _ in AnalysisResult(corrections: Corrections(), warnings: warnings) }
    }

    private struct FailingRecognizer: TextRecognizer {
        struct Failure: Error {}
        func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] { throw Failure() }
    }

    private func makeModel(scanner: MockScanner = MockScanner(previewsEnabled: false), warnings: [String] = [],
                           recognizer: any TextRecognizer = VisionTextRecognizer()) -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-log-\(UUID().uuidString)")
        let model = AppModel(scanner: scanner, store: ArchiveStore(root: dir), thumbnailSize: 64,
                             analyze: LogTests.analysis(warnings: warnings), recognizer: recognizer)
        return (model, dir)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func connectingIsLoggedAsInfo() async {
        let (model, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(model.log.count == 1)
        #expect(model.log.first?.level == .info)
        #expect(model.log.first?.text.contains("Mock-Scanner") == true)
        #expect(model.unseenIssues == 0)
        await model.disconnect()
    }

    @Test func connectionFailureIsLoggedAsError() async {
        let (model, dir) = makeModel(scanner: MockScanner(failure: .deviceNotFound)); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        #expect(model.log.first?.level == .error)
        #expect(model.log.first?.text == ScannerError.deviceNotFound.localizedDescription)
        #expect(model.unseenIssues == 1)
    }

    @Test func captureFailureIsLoggedAndShownAndCountedUntilSeen() async {
        let (model, dir) = makeModel(scanner: MockScanner(captureFailure: .timeout, previewsEnabled: false)); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        #expect(model.log.first?.level == .error)
        #expect(model.message == ScannerError.timeout.localizedDescription)
        #expect(model.unseenIssues == 1)
        model.markLogSeen()
        #expect(model.unseenIssues == 0)
        #expect(model.log.count == 2)   // Verbindung und Fehler bleiben stehen
        await model.disconnect()
    }

    @Test func analysisWarningsStayInTheLogWithTheirScanAndDoNotShowAsMessage() async throws {
        let (model, dir) = makeModel(warnings: ["Die Schräglage ist unsicher."]); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        await model.scan()
        let scanID = try #require(model.scans.first?.id)
        #expect(await eventually { model.log.contains { $0.level == .warning } })
        let entry = try #require(model.log.first { $0.level == .warning })
        #expect(entry.text == "Die Schräglage ist unsicher.")
        #expect(entry.scanID == scanID)
        #expect(model.message == nil)            // steht schon im Hinweis des Scans
        #expect(model.unseenIssues == 1)
        // Auch nach dem nächsten Scan ist die Warnung zum ersten noch nachlesbar.
        await model.scan()
        #expect(model.log.contains { $0.scanID == scanID })
        await model.disconnect()
    }

    @Test func seriesStartAndEndAreLogged() async {
        let (model, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        model.startSeries(title: "Chronik", book: true)
        await model.scan()
        model.endSeries()
        let texts = model.log.map(\.text)
        #expect(texts.contains { $0.contains("Chronik") && $0.contains("begonnen") && $0.contains("Doppelseiten") })
        #expect(texts.contains { $0.contains("Chronik") && $0.contains("beendet") && $0.contains("2 Seite") })
        await model.disconnect()
    }

    @Test func successfulExportIsLoggedAsInfoWithoutMessage() async throws {
        let (model, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        model.startSeries(title: "Export")
        await model.scan()
        let target = dir.appendingPathComponent("a.pdf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let before = model.unseenIssues
        await model.exportSeries(to: target, options: ExportOptions(dpi: 72))
        #expect(model.log.first?.level == .info)
        #expect(model.log.first?.text.contains("PDF geschrieben: 1 Seite") == true)
        #expect(model.message == nil)
        #expect(model.unseenIssues == before)
        await model.disconnect()
    }

    @Test func failedOCRIsLoggedAsWarning() async throws {
        let (model, dir) = makeModel(recognizer: FailingRecognizer()); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        model.startSeries(title: "OCR")
        await model.scan()
        var options = ExportOptions(dpi: 72); options.ocr = true
        await model.exportSeries(to: dir.appendingPathComponent("o.pdf"), options: options)
        #expect(model.log.contains { $0.level == .warning && $0.text.contains("Texterkennung schlug bei 1 Seite") })
        #expect(model.unseenIssues == 1)
        await model.disconnect()
    }

    @Test func duplicateSkipIsALoggedWarning() async {
        let (model, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.connect()
        model.startSeries(title: "Dublette")
        func page() -> FrameSignature {
            var cells = [UInt8](repeating: 230, count: FrameSignature.width * FrameSignature.height)
            for x in 4..<40 { cells[5 * FrameSignature.width + x] = 40 }
            return FrameSignature(cells: cells)!
        }
        let hand: FrameSignature = {
            var cells = [UInt8](repeating: 230, count: FrameSignature.width * FrameSignature.height)
            for i in 0..<(cells.count / 3) { cells[i] = 60 }
            return FrameSignature(cells: cells)!
        }()
        var t = 0.0
        func feed(_ f: FrameSignature, _ seconds: Double) async {
            let end = t + seconds
            while t < end - 1e-9 { await model.processSeriesFrame(f, at: t); t += 0.1 }
        }
        await feed(page(), 2); await feed(hand, 0.6); await feed(page(), 2)
        #expect(model.log.contains { $0.level == .warning && $0.text.contains("unverändert") })
        await model.disconnect()
    }

    @Test func logIsCappedAndNewestFirst() {
        let (model, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<(AppModel.logLimit + 25) { model.post(.info, "Eintrag \(i)") }
        #expect(model.log.count == AppModel.logLimit)
        #expect(model.log.first?.text == "Eintrag \(AppModel.logLimit + 24)")
        #expect(model.log.last?.text == "Eintrag 25")
    }

    @Test func logTextIsOldestFirstAndMarksTheLevel() {
        let (model, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.post(.info, "erstens")
        model.post(.warning, "zweitens")
        model.post(.error, "drittens")
        let lines = model.logText.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].contains("INFO") && lines[0].hasSuffix("erstens"))
        #expect(lines[1].contains("WARNUNG") && lines[1].hasSuffix("zweitens"))
        #expect(lines[2].contains("FEHLER") && lines[2].hasSuffix("drittens"))
    }

    @Test func clearRemovesEntriesAndCounter() {
        let (model, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.post(.error, "x")
        model.clearLog()
        #expect(model.log.isEmpty)
        #expect(model.unseenIssues == 0)
    }

    @Test func logViewRendersEntriesAndTheEmptyState() throws {
        let (model, dir) = makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let empty = ImageRenderer(content: LogPage(model: model).background(Color(nsColor: .windowBackgroundColor)))
        empty.scale = 2
        #expect(empty.cgImage != nil)
        model.post(.info, "Verbunden mit Mock-Scanner.")
        model.post(.warning, "Die Schräglage einer Seite ist unsicher.")
        model.post(.error, "Der Export ist fehlgeschlagen: Beispiel.")
        // Die Zeilen allein: ImageRenderer stellt den ScrollView des Rahmens nicht dar.
        let filled = ImageRenderer(content: LogList(model: model).frame(width: 520).background(Color(nsColor: .windowBackgroundColor)))
        filled.scale = 2
        let image = try #require(filled.cgImage)
        #expect(image.width >= 1000 && image.height >= 150)
        if let path = ProcessInfo.processInfo.environment["SCANUTIL_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path).appendingPathComponent("meldungen.png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
            }
        }
    }
}
