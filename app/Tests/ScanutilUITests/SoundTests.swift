import AppKit
import ArchiveKit
import Foundation
import ImagingKit
import ScannerKit
import Testing
@testable import ScanutilUI

/// Zählt, wie oft der Ton kommt, und merkt sich, wie viele Scans dabei schon gespeichert waren.
@MainActor
private final class RecordingSound: CaptureSound {
    private(set) var plays = 0
    var onPlay: (() -> Void)?
    func play() { plays += 1; onPlay?() }
}

@Suite("Ton")
struct BeepToneTests {
    private func u16(_ d: Data, _ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 }
    private func u32(_ d: Data, _ at: Int) -> Int { u16(d, at) | u16(d, at + 2) << 16 }
    private func sample(_ d: Data, _ i: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(d, 44 + 2 * i)))) }

    @Test func producesAValidMonoSixteenBitWav() {
        let data = BeepTone.wavData(frequency: 1000, duration: 0.1, sampleRate: 44_100)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[12..<16], as: UTF8.self) == "fmt ")
        #expect(u16(data, 20) == 1, "PCM")
        #expect(u16(data, 22) == 1, "ein Kanal")
        #expect(u32(data, 24) == 44_100)
        #expect(u32(data, 28) == 88_200, "Bytes je Sekunde")
        #expect(u16(data, 34) == 16)
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        let samples = Int(0.1 * 44_100)
        #expect(u32(data, 40) == samples * 2)
        #expect(u32(data, 4) == 36 + samples * 2, "Gesamtlänge im Kopf")
        #expect(data.count == 44 + samples * 2)
    }

    @Test func isShortAudibleAndWithoutClicks() {
        let data = BeepTone.wavData(frequency: 1000, duration: 0.12, amplitude: 0.4, fade: 0.01)
        let count = (data.count - 44) / 2
        #expect(Double(count) / 44_100 < 0.2, "kurz")
        let peak = (0..<count).map { abs(sample(data, $0)) }.max() ?? 0
        #expect(peak > Int(0.3 * 32_767), "hörbar: Spitze \(peak)")
        #expect(peak <= Int(0.4 * 32_767) + 1, "nicht lauter als eingestellt: Spitze \(peak)")
        // Ein- und Ausblenden: Anfang und Ende liegen nahe null, sonst knackt der Ton.
        #expect(abs(sample(data, 0)) < 100 && abs(sample(data, count - 1)) < 100)
        // In der Mitte schwingt der Ton mit voller Stärke.
        let middle = (count / 2 - 50..<count / 2 + 50).map { abs(sample(data, $0)) }.max() ?? 0
        #expect(middle > Int(0.3 * 32_767))
    }

    @Test func frequencyDeterminesTheNumberOfZeroCrossings() {
        let data = BeepTone.wavData(frequency: 1000, duration: 0.1, fade: 0.001)
        let count = (data.count - 44) / 2
        var crossings = 0
        for i in 1..<count where (sample(data, i - 1) < 0) != (sample(data, i) < 0) { crossings += 1 }
        // 1000 Hz über 0,1 s: 100 Schwingungen, 200 Nulldurchgänge.
        #expect(abs(crossings - 200) <= 4, "Nulldurchgänge: \(crossings)")
    }

    @Test func theDefaultToneIsLowVeryShortAndQuiet() {
        // Vorgaben des Nutzers in drei Schritten: tiefer als 1000 Hz, dann noch tiefer, ganz kurz, halbe Lautstärke (vorher 0,4).
        let data = BeepTone.wavData()
        let count = (data.count - 44) / 2
        var crossings = 0
        for i in 1..<count where (sample(data, i - 1) < 0) != (sample(data, i) < 0) { crossings += 1 }
        let seconds = Double(count) / 44_100
        let hertz = Double(crossings) / 2 / seconds
        #expect(BeepTone.defaultFrequency <= 400, "Der Ton ist mit \(BeepTone.defaultFrequency) Hz nicht tief genug")
        #expect(abs(hertz - BeepTone.defaultFrequency) < 30, "Gemessene Tonhöhe \(hertz) Hz statt \(BeepTone.defaultFrequency) Hz")
        #expect(seconds <= 0.08, "Der Ton dauert \(seconds) s, soll ganz kurz sein")
        let peak = (0..<count).map { abs(sample(data, $0)) }.max() ?? 0
        #expect(Double(peak) <= 0.2 * 32_767 + 1, "Der Ton ist mit Spitze \(peak) lauter als die halbe Lautstärke")
        #expect(Double(peak) >= 0.15 * 32_767, "Der Ton ist zu leise: Spitze \(peak)")
        // Auch der kurze Ton knackt nicht: Anfang und Ende liegen nahe null.
        #expect(abs(sample(data, 0)) < 100 && abs(sample(data, count - 1)) < 100)
    }

    @Test @MainActor func theSystemCanPlayTheGeneratedData() {
        #expect(NSSound(data: BeepTone.wavData()) != nil, "NSSound kann die erzeugten Daten nicht lesen")
    }

    @Test(arguments: [0.0, -1.0]) func degenerateDurationStillGivesAValidFile(duration: Double) {
        let data = BeepTone.wavData(duration: duration)
        #expect(data.count >= 46)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
    }
}

@MainActor
@Suite("Ton in der Serie")
struct SeriesSoundTests {
    nonisolated private static let none: @Sendable (CGImage) -> AnalysisResult = { _ in AnalysisResult(corrections: Corrections(), warnings: []) }

    private func makeModel(scanner: MockScanner = MockScanner(previewsEnabled: false), defaults: UserDefaults? = nil)
        async -> (AppModel, RecordingSound, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-snd-\(UUID().uuidString)")
        let sound = RecordingSound()
        let model = AppModel(scanner: scanner, store: ArchiveStore(root: dir), thumbnailSize: 64, analyze: Self.none,
                             sound: sound, defaults: defaults)
        await model.connect()
        return (model, sound, dir)
    }

    private func page(row: Int?) -> FrameSignature {
        var cells = [UInt8](repeating: 230, count: FrameSignature.width * FrameSignature.height)
        if let row { for x in 4..<40 { cells[row * FrameSignature.width + x] = 40 } }
        return FrameSignature(cells: cells)!
    }

    private func suite() -> (UserDefaults, String) {
        let name = "scanutil-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func everyCaptureInASeriesBeeps() async {
        let (model, sound, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Ton")
        await model.scan()
        #expect(sound.plays == 1)
        await model.scan()
        #expect(sound.plays == 2)
        await model.disconnect()
    }

    @Test func aBookCaptureBeepsOncePerCaptureNotPerPage() async {
        let (model, sound, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Buch", book: true)
        await model.scan()
        #expect(model.series?.pages.count == 2)
        #expect(sound.plays == 1)
        await model.disconnect()
    }

    @Test func theAutomaticCaptureBeepsToo() async {
        let (model, sound, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Auto")
        var t = 0.0
        while t < 2.0 { await model.processSeriesFrame(page(row: 5), at: t); t += 0.1 }
        #expect(model.scans.count == 1)
        #expect(sound.plays == 1)
        await model.disconnect()
    }

    @Test func noBeepOutsideASeries() async {
        let (model, sound, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        await model.scan()
        #expect(model.scans.count == 1)
        #expect(sound.plays == 0)
        await model.disconnect()
    }

    @Test func noBeepWhenSwitchedOff() async {
        let (model, sound, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.soundEnabled = false
        model.startSeries(title: "Still")
        await model.scan()
        #expect(model.scans.count == 1)
        #expect(sound.plays == 0)
        model.soundEnabled = true
        await model.scan()
        #expect(sound.plays == 1)
        await model.disconnect()
    }

    @Test func noBeepWhenTheCaptureFails() async {
        let scanner = MockScanner(captureFailure: .timeout, previewsEnabled: false)
        let (model, sound, dir) = await makeModel(scanner: scanner); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Fehler")
        await model.scan()
        #expect(model.scans.isEmpty)
        #expect(sound.plays == 0, "Eine Aufnahme, die nicht kam, darf nicht als gemacht gemeldet werden")
        await model.disconnect()
    }

    @Test func noBeepForASkippedDuplicate() async {
        let (model, sound, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Dublette")
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
        await feed(page(row: 5), 2); await feed(hand, 0.6); await feed(page(row: 5), 2)
        #expect(model.scans.count == 1)
        #expect(sound.plays == 1, "Nur die erste Aufnahme piept, die übersprungene Dublette nicht")
        await model.disconnect()
    }

    @Test func theBeepComesBeforeTheScanIsSaved() async throws {
        // Ab dem Ton darf umgeblättert werden: er kommt, sobald das Bild da ist, nicht erst nach dem Speichern (fast eine Sekunde).
        let (model, sound, dir) = await makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        model.startSeries(title: "Reihenfolge")
        let archive = ArchiveStore(root: dir)
        var onDiskWhenBeeping: Int?
        var listedWhenBeeping: Int?
        sound.onPlay = {
            onDiskWhenBeeping = (try? archive.allRecords().count)
            listedWhenBeeping = model.scans.count
        }
        await model.scan()
        #expect(onDiskWhenBeeping == 0, "Beim Ton lagen schon \(String(describing: onDiskWhenBeeping)) Originale auf der Platte")
        #expect(listedWhenBeeping == 0)
        #expect(model.scans.count == 1)
        #expect(try archive.allRecords().count == 1)
        await model.disconnect()
    }

    // MARK: Einstellung

    @Test func soundIsOnByDefault() async {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let (model, _, dir) = await makeModel(defaults: defaults); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.soundEnabled)
        await model.disconnect()
    }

    @Test func theSettingIsKeptAcrossLaunches() async {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let (first, _, dir1) = await makeModel(defaults: defaults); defer { try? FileManager.default.removeItem(at: dir1) }
        first.soundEnabled = false
        let (second, _, dir2) = await makeModel(defaults: defaults); defer { try? FileManager.default.removeItem(at: dir2) }
        #expect(second.soundEnabled == false, "Der Ton war nach dem Neustart wieder an")
        second.soundEnabled = true
        let (third, _, dir3) = await makeModel(defaults: defaults); defer { try? FileManager.default.removeItem(at: dir3) }
        #expect(third.soundEnabled)
        await first.disconnect(); await second.disconnect(); await third.disconnect()
    }

    @Test func withoutDefaultsNothingIsStored() async {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let (model, _, dir) = await makeModel(defaults: nil); defer { try? FileManager.default.removeItem(at: dir) }
        model.soundEnabled = false
        let (other, _, dir2) = await makeModel(defaults: defaults); defer { try? FileManager.default.removeItem(at: dir2) }
        #expect(other.soundEnabled, "Ohne Einstellungsspeicher darf nichts in fremde Einstellungen wandern")
        await model.disconnect(); await other.disconnect()
    }
}
