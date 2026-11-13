import ArchiveKit
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

@MainActor
@Suite("Ruhezeit der Auto-Auslösung")
struct AutoTriggerCalmTests {
    private func makeModel(defaults: UserDefaults? = nil) async -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-calm-\(UUID().uuidString)")
        let model = AppModel(scanner: MockScanner(previewsEnabled: false), store: ArchiveStore(root: dir), thumbnailSize: 64,
                             sound: SilentSound(), defaults: defaults)
        await model.connect()
        return (model, dir)
    }

    private func page(_ row: Int?) -> FrameSignature {
        var cells = [UInt8](repeating: 230, count: FrameSignature.width * FrameSignature.height)
        if let row { for x in 4..<40 { cells[row * FrameSignature.width + x] = 40 } }
        return FrameSignature(cells: cells)!
    }

    /// Spielt ein stehendes Bild ab Sekunde 0 vor und meldet, ab welcher Sekunde aufgenommen wurde (oder `nil`).
    private func firstCapture(_ model: AppModel, until limit: Double) async -> Double? {
        var t = 0.0
        while t <= limit {
            await model.processSeriesFrame(page(5), at: t)
            if !model.scans.isEmpty { return t }
            t += 0.1
        }
        return nil
    }

    @Test func theDefaultIsLongerThanTheOldEightTenthsOfASecond() async {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.autoTriggerCalm == 1.6)
        model.startSeries(title: "Ruhe")
        let when = await firstCapture(model, until: 4)
        #expect(when != nil && when! >= 1.5, "Aufnahme erst nach der Ruhezeit: \(String(describing: when))")
        await model.disconnect()
    }

    @Test func theSettingChangesWhenTheSeriesCaptures() async {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.autoTriggerCalm = 0.6
        model.startSeries(title: "Kurz")
        let when = await firstCapture(model, until: 4)
        #expect(when != nil && when! < 1.0, "Kurze Ruhezeit: \(String(describing: when))")
        await model.disconnect()

        let (long, dir2) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir2) }
        long.autoTriggerCalm = 3.0
        long.startSeries(title: "Lang")
        #expect(await firstCapture(long, until: 2.5) == nil, "Nach 2,5 s darf bei 3 s Ruhezeit noch nichts aufgenommen sein")
        await long.disconnect()
    }

    @Test func aChangeDuringARunningSeriesAppliesAtOnce() async {
        let (model, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Laufend")
        model.autoTriggerCalm = 0.6
        let when = await firstCapture(model, until: 4)
        #expect(when != nil && when! < 1.0)
        await model.disconnect()
    }

    @Test func theSettingIsSavedAndKeptInsideItsLimits() async {
        let suite = UserDefaults(suiteName: "scanutil-calm-\(UUID().uuidString)")!
        let (first, d1) = await makeModel(defaults: suite); defer { try? FileManager.default.removeItem(at: d1) }
        first.autoTriggerCalm = 2.4
        let (second, d2) = await makeModel(defaults: suite); defer { try? FileManager.default.removeItem(at: d2) }
        #expect(second.autoTriggerCalm == 2.4)
        suite.set(99.0, forKey: "autoTriggerCalm")
        let (clamped, d3) = await makeModel(defaults: suite); defer { try? FileManager.default.removeItem(at: d3) }
        #expect(clamped.autoTriggerCalm == AppModel.calmRange.upperBound, "Ein unsinniger gespeicherter Wert wird begrenzt")
        suite.set(0.0, forKey: "autoTriggerCalm")
        let (low, d4) = await makeModel(defaults: suite); defer { try? FileManager.default.removeItem(at: d4) }
        #expect(low.autoTriggerCalm == AppModel.calmRange.lowerBound)
    }
}
