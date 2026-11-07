import Testing
@testable import ScannerKit

@Suite("Bilder in fremder Form verwerfen")
struct FrameFormatGuardTests {
    private let good = FrameFormat(pixelFormat: 875704438, bytesPerRow: 5696, planes: 2, dataSize: 36_000_000)
    private let odd = FrameFormat(pixelFormat: 875704422, bytesPerRow: 5700, planes: 3, dataSize: 36_100_000)

    /// Eine Hülle mit Verweissemantik, damit sich die Wache in `#expect(…)` aufrufen lässt.
    private final class Guard {
        var value = FrameFormatGuard()
        func accept(_ f: FrameFormat) -> Bool { value.accept(f) }
        var rejected: Int { value.rejected }
    }

    private func primed() -> Guard {
        let g = Guard()
        for _ in 0..<FrameFormatGuard.votingFrames { _ = g.accept(good) }
        return g
    }

    @Test func everythingCountsWhileTheUsualFormIsStillUnknown() {
        let g = Guard()
        for _ in 0..<(FrameFormatGuard.votingFrames - 1) { #expect(g.accept(good)) }
        #expect(g.accept(good))
        #expect(g.rejected == 0)
    }

    @Test func theMostFrequentFormatAmongTheFirstFramesIsTheUsualOne() {
        let g = Guard()
        // Zwei ungewöhnliche Bilder gleich am Anfang ändern nichts an der Wahl.
        _ = g.accept(odd); _ = g.accept(odd)
        for _ in 0..<(FrameFormatGuard.votingFrames - 2) { _ = g.accept(good) }
        #expect(g.accept(good), "Das übliche Format gilt")
        #expect(!g.accept(odd), "Das seltene wird verworfen")
    }

    @Test func aDifferentFormatIsRejectedAndSoAreTheNextFewGoodOnes() {
        let g = primed()
        #expect(g.accept(good))
        #expect(!g.accept(odd))
        for _ in 0..<FrameFormatGuard.settleFrames { #expect(!g.accept(good), "Noch nicht beruhigt") }
        #expect(g.accept(good), "Danach gilt es wieder")
        #expect(g.rejected == 1 + FrameFormatGuard.settleFrames)
    }

    @Test func aNewDeviantFrameRestartsTheSettling() {
        let g = primed()
        _ = g.accept(odd)
        _ = g.accept(good); _ = g.accept(good)
        _ = g.accept(odd)
        for _ in 0..<FrameFormatGuard.settleFrames { #expect(!g.accept(good)) }
        #expect(g.accept(good))
    }

    @Test func aStreamThatStaysDifferentIsAcceptedEventuallySoNothingDeadlocks() {
        let g = primed()
        var accepted = 0
        for _ in 0..<(FrameFormatGuard.giveUpAfter + 5) where g.accept(odd) { accepted += 1 }
        #expect(accepted >= 1, "Nach dauerhafter Abweichung gilt die neue Form")
        #expect(g.accept(odd))
    }
}
