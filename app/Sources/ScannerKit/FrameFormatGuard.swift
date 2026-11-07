import Foundation

/// Wie ein Bild des Scanners im Speicher liegt: Pixelformat, Zeilenlänge, Ebenen, Größe. Alle guten Bilder eines Stroms haben
/// dieselbe Form.
public struct FrameFormat: Hashable, Sendable, CustomStringConvertible {
    public let pixelFormat: UInt32
    public let bytesPerRow: Int
    public let planes: Int
    public let dataSize: Int

    public init(pixelFormat: UInt32, bytesPerRow: Int, planes: Int, dataSize: Int) {
        self.pixelFormat = pixelFormat
        self.bytesPerRow = bytesPerRow
        self.planes = planes
        self.dataSize = dataSize
    }

    public var description: String { "Format \(pixelFormat), Zeile \(bytesPerRow) B, \(planes) Ebene(n), \(dataSize) B" }
}

/// Wacht darüber, dass nur Bilder in der üblichen Form durchkommen. Löst der Scanner selbst eine Aufnahme aus (Taste am Gerät,
/// Fußtaster), liefert er kurz Bilder in einer anderen Form; sie werden als Bildsalat gelesen (grüne Streifen, Rauschen).
/// Solche Bilder und die nächsten paar danach gelten nicht.
///
/// Die übliche Form ist die häufigste unter den ersten Bildern eines Stroms. Bis dahin zählt alles.
public struct FrameFormatGuard: Sendable {
    /// So viele Bilder stimmen über die übliche Form ab.
    public static let votingFrames = 10
    /// So viele gute Bilder in Folge müssen nach einer Abweichung kommen, bevor wieder aufgenommen wird.
    public static let settleFrames = 5
    /// Weicht der Strom dauerhaft ab (so viele Bilder in Folge), war die Wahl falsch: Dann gilt die neue Form.
    public static let giveUpAfter = 150

    private var votes: [FrameFormat: Int] = [:]
    private var seen = 0
    private var usual: FrameFormat?
    private var settling = 0
    private var rejectedInARow = 0
    /// Wie viele Bilder insgesamt verworfen wurden.
    public private(set) var rejected = 0

    public init() {}

    /// Ob das Bild gilt.
    public mutating func accept(_ format: FrameFormat) -> Bool {
        if usual == nil {
            votes[format, default: 0] += 1
            seen += 1
            if seen >= Self.votingFrames { usual = votes.max { $0.value < $1.value }?.key }
            return true
        }
        if format == usual {
            rejectedInARow = 0
            if settling > 0 { settling -= 1; rejected += 1; return false }
            return true
        }
        rejected += 1
        rejectedInARow += 1
        settling = Self.settleFrames
        if rejectedInARow >= Self.giveUpAfter {
            usual = format
            rejectedInARow = 0
            settling = 0
            return true
        }
        return false
    }
}
