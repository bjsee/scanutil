import AppKit
import Foundation

/// Der Ton, der in einer Serie anzeigt, dass eine Aufnahme gemacht wurde: danach darf man die Seite umblättern.
@MainActor
public protocol CaptureSound {
    func play()
}

/// Kein Ton. Für Tests und die Oberflächentests, die nicht piepen sollen.
public struct SilentSound: CaptureSound {
    public init() {}
    public func play() {}
}

/// Ein kurzer Ton, den die App selbst erzeugt. Anders als `NSSound.beep()` ist er nicht still, wenn die Alarmlautstärke
/// des Systems auf null steht, und klingt auf jedem Rechner gleich.
@MainActor
public final class BeepSound: CaptureSound {
    private let sound: NSSound?

    /// Ohne Angaben gilt der Standardton von `BeepTone`.
    public init(frequency: Double? = nil, duration: Double? = nil) {
        sound = NSSound(data: BeepTone.wavData(frequency: frequency ?? BeepTone.defaultFrequency,
                                               duration: duration ?? BeepTone.defaultDuration))
    }

    public func play() {
        // Folgt die nächste Aufnahme dicht auf die letzte, soll der Ton neu beginnen statt zu verstummen.
        sound?.stop()
        sound?.play()
    }
}

/// Erzeugt den Ton als WAV-Daten im Speicher: 16 Bit, ein Kanal, ohne Datei.
enum BeepTone {
    /// Tonhöhe des Aufnahmetons. Zuerst 1000 Hz, dann 600 Hz: beides war zu hell.
    static let defaultFrequency = 400.0
    /// Ganz kurz: ein Tick, der anzeigt „aufgenommen“, nicht ein Piepen, auf das man wartet.
    static let defaultDuration = 0.06
    /// Halb so laut wie zuerst (0,4).
    static let defaultAmplitude = 0.2
    /// Ein- und Ausblenden, kurz genug für den kurzen Ton und lang genug gegen Knacken.
    static let defaultFade = 0.006

    /// - Parameters:
    ///   - amplitude: Höchster Ausschlag von 0 bis 1.
    ///   - fade: Ein- und Ausblenden in Sekunden, damit am Anfang und Ende kein Knacken entsteht.
    static func wavData(frequency: Double = defaultFrequency, duration: Double = defaultDuration, sampleRate: Int = 44_100,
                        amplitude: Double = defaultAmplitude, fade: Double = defaultFade) -> Data {
        let count = max(1, Int(duration * Double(sampleRate)))
        let fadeSamples = max(1, Int(fade * Double(sampleRate)))
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let envelope = min(1, Double(i) / Double(fadeSamples), Double(count - 1 - i) / Double(fadeSamples))
            let value = amplitude * envelope * sin(2 * .pi * frequency * Double(i) / Double(sampleRate))
            samples[i] = Int16((value * Double(Int16.max)).rounded())
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let dataSize = UInt32(count * MemoryLayout<Int16>.size)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + dataSize); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for sample in samples { append(sample) }
        return data
    }
}
