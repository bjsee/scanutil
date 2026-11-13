import Testing
import CoreGraphics
import Foundation
@testable import ImagingKit

/// Hände, Daumen und die gelben Daumen-Marker: erkennen und entfernen. Mit künstlichen Bildern, deren Farben an echten
/// Aufnahmen gemessen sind (Marker: Farbton 49–60°, Sättigung 0,5 bis 1; Papier: Sättigung unter 0,06).
@Suite("Hände und Marker")
struct HandTests {
    // Farben (R, G, B)
    private let cloth: (UInt8, UInt8, UInt8) = (12, 12, 14)
    private let paper: (UInt8, UInt8, UInt8) = (238, 233, 218)
    private let skin: (UInt8, UInt8, UInt8) = (205, 150, 125)
    private let yellow: (UInt8, UInt8, UInt8) = (250, 232, 40)
    private let green: (UInt8, UInt8, UInt8) = (30, 140, 50)

    /// Ein Bild aus Rechtecken und Ellipsen, von hinten nach vorn.
    private struct Canvas {
        let width: Int, height: Int
        var pixels: [UInt8]
        init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8)) {
            self.width = width; self.height = height
            pixels = (0..<(width * height)).flatMap { _ in [fill.0, fill.1, fill.2, 255] }
        }
        mutating func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: (UInt8, UInt8, UInt8)) {
            for y in max(0, y0)..<min(height, y1) { for x in max(0, x0)..<min(width, x1) { set(x, y, c) } }
        }
        mutating func ellipse(cx: Int, cy: Int, rx: Int, ry: Int, _ c: (UInt8, UInt8, UInt8)) {
            for y in max(0, cy - ry)..<min(height, cy + ry + 1) { for x in max(0, cx - rx)..<min(width, cx + rx + 1) {
                let dx = Double(x - cx) / Double(rx), dy = Double(y - cy) / Double(ry)
                if dx * dx + dy * dy <= 1 { set(x, y, c) }
            } }
        }
        mutating func set(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
            let i = (y * width + x) * 4; pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2
        }
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * width + x) * 4; return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])) }
        func image() -> CGImage {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
    }

    /// Papierseite 800×600 auf Tuch, von (100, 60) bis (700, 540), mit etwas Text.
    private func bookPage() -> Canvas {
        var c = Canvas(width: 800, height: 600, fill: cloth)
        c.rect(100, 60, 700, 540, paper)
        for row in 0..<12 { c.rect(180, 130 + row * 30, 620, 136 + row * 30, (30, 30, 30)) }
        return c
    }

    private let pageQuad = Quad(topLeft: .init(x: 100.0 / 800, y: 60.0 / 600), topRight: .init(x: 700.0 / 800, y: 60.0 / 600),
                                bottomRight: .init(x: 700.0 / 800, y: 540.0 / 600), bottomLeft: .init(x: 100.0 / 800, y: 540.0 / 600))

    // MARK: Farben

    @Test func skinTonesAreSkinAndPaperClothAndCoverAreNot() {
        for tone in [(205, 150, 125), (190, 135, 110), (225, 170, 145), (160, 105, 85)] {
            #expect(HandDetector.isSkin(r: UInt8(tone.0), g: UInt8(tone.1), b: UInt8(tone.2)), "Hautton \(tone)")
        }
        #expect(!HandDetector.isSkin(r: paper.0, g: paper.1, b: paper.2), "Cremeweißes Papier")
        #expect(!HandDetector.isSkin(r: cloth.0, g: cloth.1, b: cloth.2), "Schwarzes Tuch")
        #expect(!HandDetector.isSkin(r: green.0, g: green.1, b: green.2), "Grüner Einband")
        #expect(!HandDetector.isSkin(r: 255, g: 255, b: 255), "Weiß")
        #expect(!HandDetector.isSkin(r: 95, g: 55, b: 30), "Der gelbliche Widerschein der Marker auf dem Tuch (Helligkeit unter 0,4) ist keine Hand")
    }

    @Test func markerYellowIncludingGlareButNotPaperOrSkin() {
        #expect(HandDetector.isMarkerYellow(r: yellow.0, g: yellow.1, b: yellow.2))
        #expect(HandDetector.isMarkerYellow(r: 255, g: 250, b: 195), "Überstrahlte Glanzstelle des Plastiks")
        #expect(HandDetector.isMarkerYellow(r: 215, g: 190, b: 20), "Dunklere Marker im Schatten")
        #expect(!HandDetector.isMarkerYellow(r: paper.0, g: paper.1, b: paper.2), "Cremeweißes Papier")
        #expect(!HandDetector.isMarkerYellow(r: 255, g: 255, b: 255))
        #expect(!HandDetector.isMarkerYellow(r: skin.0, g: skin.1, b: skin.2), "Haut")
        #expect(!HandDetector.isMarkerYellow(r: green.0, g: green.1, b: green.2), "Grün")
        #expect(!HandDetector.isMarkerYellow(r: cloth.0, g: cloth.1, b: cloth.2))
    }

    // MARK: Erkennen

    @Test func findsAThumbAtTheBottomCornerThatTouchesTheImageBorder() throws {
        var c = bookPage()
        c.ellipse(cx: 130, cy: 560, rx: 60, ry: 70, skin)   // ragt von unten auf die Seitenecke
        let detection = try #require(HandDetector.detect(in: c.image()))
        #expect(detection.regions == 1 && detection.markers == 0)
        let mask = detection.mask
        func hand(_ x: Int, _ y: Int) -> Bool { mask.cells[(y * mask.height / 600) * mask.width + (x * mask.width / 800)] > 127 }
        #expect(hand(130, 560), "Mitte des Daumens")
        #expect(hand(130, 520), "Teil des Daumens auf dem Papier")
        #expect(!hand(400, 300), "Papier in der Mitte")
        #expect(!hand(650, 100), "Papier oben rechts")
    }

    @Test func findsNothingOnPlainPaperClothAndGreenCover() {
        var c = bookPage()
        c.rect(100, 60, 180, 540, green)   // grüner Einband am Rand
        #expect(HandDetector.detect(in: c.image()) == nil)
        #expect(HandDetector.detect(in: c.image(), page: pageQuad) == nil)
    }

    @Test func aSkinColoredDrawingInTheMiddleOfThePageIsNotAHand() {
        var c = bookPage()
        c.ellipse(cx: 400, cy: 300, rx: 70, ry: 60, skin)   // Foto oder Zeichnung mitten auf der Seite
        #expect(HandDetector.detect(in: c.image(), page: pageQuad) == nil, "Nur Flächen am Rand der Seite zählen")
    }

    @Test func aThumbRestingOnThePageEdgeIsFoundWithThePageKnownEvenWithoutTouchingTheImageBorder() throws {
        var c = bookPage()
        c.ellipse(cx: 105, cy: 300, rx: 40, ry: 60, skin)   // Daumen am linken Seitenrand, Hand nicht im Bild
        #expect(HandDetector.detect(in: c.image()) == nil, "Ohne Seitenrand berührt er den Bildrand nicht")
        let found = try #require(HandDetector.detect(in: c.image(), page: pageQuad))
        #expect(found.regions == 1)
    }

    @Test func findsAMarkerWithItsDotPatternAndCountsItAsMarker() throws {
        var c = bookPage()
        c.rect(640, 380, 760, 440, yellow)                       // Marker, ragt über den rechten Seitenrand
        // Punktfeld wie am echten Marker: am Rand, zu einer Seite offen, nicht von Gelb umschlossen. Löcherfüllen allein
        // erreicht es nicht, erst das Schließen mit großem Radius.
        c.rect(640, 388, 690, 432, (240, 240, 240))
        for k in 0..<3 { c.ellipse(cx: 656 + k * 12, cy: 410, rx: 4, ry: 4, (20, 20, 20)) }
        let detection = try #require(HandDetector.detect(in: c.image()))
        #expect(detection.markers == 1)
        let mask = detection.mask
        func covered(_ x: Int, _ y: Int) -> Bool { mask.cells[(y * mask.height / 600) * mask.width + (x * mask.width / 800)] > 127 }
        #expect(covered(740, 410), "Gelber Teil")
        #expect(covered(656, 410), "Das Punktfeld gehört zum Marker")
        #expect(!covered(300, 300))
    }

    /// Ein Marker am rechten Seitenrand (Papier bis x=700), Punktfeld wie am echten Marker.
    private func pageWithMarker() -> Canvas {
        var c = bookPage()
        c.rect(640, 380, 760, 440, yellow)
        c.rect(640, 388, 690, 432, (240, 240, 240))
        for k in 0..<3 { c.ellipse(cx: 656 + k * 12, cy: 410, rx: 4, ry: 4, (20, 20, 20)) }
        return c
    }

    private func covered(_ mask: HandMask, _ x: Int, _ y: Int) -> Bool {
        mask.cells[(y * mask.height / 600) * mask.width + (x * mask.width / 800)] > 127
    }

    @Test func theShadowOfAMarkerIsCoveredToo() throws {
        // Der Marker wirft einen weichen, etwas dunkleren Schatten aufs Papier. Bliebe er stehen, sähe man neben der Füllung einen Saum.
        var c = pageWithMarker()
        c.rect(630, 440, 690, 462, (186, 186, 180))      // Schatten unter dem Marker
        c.rect(612, 380, 640, 440, (186, 186, 180))      // und links davon
        let mask = try #require(HandDetector.detect(in: c.image())).mask
        #expect(covered(mask, 660, 452), "Schatten unter dem Marker")
        #expect(covered(mask, 622, 410), "Schatten links vom Marker")
        #expect(!covered(mask, 660, 520), "Weiter weg bleibt das Papier")
    }

    @Test func textNextToAMarkerIsNotEatenByTheMask() throws {
        // Schrift dicht neben dem Marker (Zeilenanfänge an der Papierkante) gehört nicht zum Marker, auch nicht zu seinem Schatten:
        // Sie wäre sonst im fertigen Bild weg. Die Schriftzeilen reichen hier bis 6 Pixel an den Marker heran (x = 634, Marker ab 640).
        var c = pageWithMarker()
        for row in 0..<4 { c.rect(540, 372 + row * 22, 634, 378 + row * 22, (30, 30, 30)) }
        let mask = try #require(HandDetector.detect(in: c.image())).mask
        #expect(covered(mask, 700, 410), "Der Marker selbst")
        for row in 0..<4 { #expect(!covered(mask, 626, 375 + row * 22), "Schriftzeile \(row) liegt in der Maske") }
    }

    @Test func fillNextToAMarkerIsNotBrighterThanTheDimPaperAroundIt() throws {
        // Papier mit Helligkeitsverlauf zum Rand: Die Füllung darf nicht aus den hellsten Stellen allein gerechnet werden.
        var c = bookPage()
        for y in 0..<600 { for x in 100..<700 {
            let v = UInt8(150 + (x - 100) * 90 / 600)    // 150 am linken Rand bis 240 rechts
            c.set(x, y, (v, v, UInt8(max(0, Int(v) - 8))))
        } }
        c.rect(100, 380, 220, 440, yellow)
        let image = c.image()
        let detection = try #require(HandDetector.detect(in: image, page: pageQuad))
        let cleaned = try #require(HandRemover.apply(to: image, mask: detection.mask))
        let rgb = try #require(RGBBitmap(cleaned, width: 800))
        let filled = Int(rgb.pixels[(410 * 800 + 160) * 4]), around = 150 + (160 - 100) * 90 / 600
        #expect(abs(filled - around) < 22, "Füllung \(filled), Papier ringsum \(around)")
    }

    @Test func tinySpecksAreIgnored() {
        var c = bookPage()
        c.rect(300, 580, 306, 586, skin)
        c.rect(500, 20, 505, 25, yellow)
        #expect(HandDetector.detect(in: c.image()) == nil)
    }

    @Test func aHugeYellowAreaIsACoverNotAMarker() {
        var c = bookPage()
        c.rect(0, 0, 800, 600, yellow)   // das ganze Bild gelb
        #expect(HandDetector.detect(in: c.image()) == nil)
    }

    @Test func maskSurvivesThePNGRoundTrip() throws {
        var c = bookPage()
        c.ellipse(cx: 130, cy: 560, rx: 60, ry: 70, skin)
        let mask = try #require(HandDetector.detect(in: c.image())?.mask)
        let data = try #require(mask.pngData())
        #expect(data.count < 20_000, "Die Maske soll klein bleiben: \(data.count) Bytes")
        #expect(HandMask(pngData: data) == mask)
        #expect(HandMask(pngData: Data([1, 2, 3])) == nil)
    }

    @Test func unionCoversBoth() throws {
        var a = bookPage(); a.ellipse(cx: 130, cy: 560, rx: 60, ry: 70, skin)
        var b = bookPage(); b.ellipse(cx: 680, cy: 565, rx: 60, ry: 70, skin)
        let da = try #require(HandDetector.detect(in: a.image())), db = try #require(HandDetector.detect(in: b.image()))
        let both = try #require(HandDetector.union(da, db))
        #expect(both.mask.coverage >= max(da.mask.coverage, db.mask.coverage))
        #expect(both.mask.coverage > da.mask.coverage)
        #expect(HandDetector.union(nil, da) == da && HandDetector.union(da, nil) == da && HandDetector.union(nil, nil) == nil)
    }

    // MARK: Entfernen

    @Test func harmonicFillReproducesALinearGradientInsideAHole() {
        let w = 40, h = 30
        var values = [Float](repeating: 0, count: w * h)
        var known = [Bool](repeating: true, count: w * h)
        for y in 0..<h { for x in 0..<w { values[y * w + x] = Float(x) / Float(w - 1) } }
        let truth = values
        for y in 10..<20 { for x in 12..<28 { known[y * w + x] = false; values[y * w + x] = 0.5 } }
        HandRemover.harmonicFill(&values, known: known, width: w, height: h, channels: 1)
        var error: Float = 0
        for y in 10..<20 {
            for x in 12..<28 { error = max(error, abs(values[y * w + x] - truth[y * w + x])) }
        }
        #expect(error < 0.05, "Größte Abweichung im Loch: \(error)")
    }

    @Test func removalReplacesTheThumbWithPaperAndLeavesTheRestAlone() throws {
        var c = bookPage()
        let original = c
        c.ellipse(cx: 160, cy: 500, rx: 45, ry: 40, skin)    // Daumen mitten auf der unteren Seitenecke, ganz auf dem Papier
        c.ellipse(cx: 160, cy: 580, rx: 50, ry: 50, skin)    // und der Finger darunter, ragt aus dem Bild
        let mask = try #require(HandDetector.detect(in: c.image())?.mask)
        let cleaned = try #require(HandRemover.apply(to: c.image(), mask: mask))
        let rgb = try #require(RGBBitmap(cleaned, width: 800))
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * 800 + x) * 4; return (Int(rgb.pixels[i]), Int(rgb.pixels[i + 1]), Int(rgb.pixels[i + 2])) }

        let thumb = px(160, 500)
        #expect(thumb.0 > 215 && thumb.1 > 210 && thumb.2 > 195, "Der Daumen ist durch Papier ersetzt: \(thumb)")
        // Weit von der Hand: unverändert.
        for (x, y) in [(500, 200), (650, 480), (400, 300), (30, 30)] {
            let a = px(x, y), b = original.pixel(x, y)
            #expect(abs(a.0 - b.0) <= 2 && abs(a.1 - b.1) <= 2 && abs(a.2 - b.2) <= 2, "Stelle (\(x), \(y)) hat sich verändert: \(a) statt \(b)")
        }
        // Der Teil über dem Tuch wird nicht zu Papier.
        let overCloth = px(160, 590)
        #expect(overCloth.0 < 90, "Ein Finger über dem Tuch wird Tuch, nicht Papier: \(overCloth)")
    }

    @Test func insideThePageTheFillIsAlwaysPaperNeverCloth() throws {
        // Ein Marker über der oberen linken Ecke der Seite: Das Tuch liegt dem Papier unter dem Marker näher als das sichtbare Papier.
        var c = bookPage()
        c.ellipse(cx: 140, cy: 95, rx: 70, ry: 55, yellow)
        let mask = try #require(HandDetector.detect(in: c.image(), page: pageQuad)?.mask)
        let withPage = try #require(HandRemover.apply(to: c.image(), mask: mask, page: pageQuad))
        let withoutPage = try #require(HandRemover.apply(to: c.image(), mask: mask))
        func red(_ image: CGImage, _ x: Int, _ y: Int) throws -> Int {
            let rgb = try #require(RGBBitmap(image, width: 800)); return Int(rgb.pixels[(y * 800 + x) * 4])
        }
        // Eine Stelle auf dem Papier, dicht an der Ecke.
        let clothInPaper = try red(withoutPage, 108, 68), paperInPage = try red(withPage, 108, 68), clothOutside = try red(withPage, 108, 30)
        #expect(clothInPaper < 120, "Ohne Seitenrand zieht das Tuch ins Papier: Das ist der Fall, den der Test fassen soll (\(clothInPaper))")
        #expect(paperInPage > 200, "Innerhalb der Seite füllt Papier: \(paperInPage)")
        // Über dem Tuch außerhalb der Seite bleibt es Tuch.
        #expect(clothOutside < 90, "Außerhalb der Seite bleibt das Tuch: \(clothOutside)")
    }

    @Test func theFillMatchesThePaperBetweenDenseTextLinesAndDoesNotTurnGray() throws {
        // Dichte Zeilen rings um den Marker: Die Zellen des groben Füllrasters mitteln Schrift und Papier. Mit diesem Mischton gefüllt,
        // bliebe an der Stelle des Markers ein grauer Fleck. Dazu ein dunkler Randsaum der Seite, der nicht als Papier zählen darf.
        var c = Canvas(width: 1600, height: 1200, fill: cloth)
        c.rect(200, 120, 1400, 1080, paper)
        c.rect(1388, 120, 1400, 1080, (120, 118, 110))                      // Randsaum der Seite
        // Feine Schrift: Zeilen aus senkrechten Strichen (1 von 4 Punkten dunkel, 10 Punkte hoch, alle 17 Punkte), bis dicht an den Marker.
        // Eine Zelle des Füllrasters (vier Bildpunkte breit) mittelt dann Schrift und Papier zu deutlich dunkler als das Papier.
        for row in 0..<55 { for x in stride(from: 260, to: 1380, by: 4) { c.rect(x, 150 + row * 17, x + 1, 160 + row * 17, (30, 30, 30)) } }
        c.ellipse(cx: 1400, cy: 600, rx: 110, ry: 70, yellow)               // Marker am rechten Seitenrand
        let quad = Quad(topLeft: .init(x: 200.0 / 1600, y: 120.0 / 1200), topRight: .init(x: 1400.0 / 1600, y: 120.0 / 1200),
                        bottomRight: .init(x: 1400.0 / 1600, y: 1080.0 / 1200), bottomLeft: .init(x: 200.0 / 1600, y: 1080.0 / 1200))
        let mask = try #require(HandDetector.detect(in: c.image(), page: quad)?.mask)
        let cleaned = try #require(HandRemover.apply(to: c.image(), mask: mask, page: quad))
        let rgb = try #require(RGBBitmap(cleaned, width: 1600))
        // Hellster Wert in der Mitte der Füllung: so hell wie das Papier daneben.
        var brightest = 0
        for y in 590..<606 { for x in 1330..<1380 { brightest = max(brightest, Int(rgb.pixels[(y * 1600 + x) * 4])) } }
        var mean = 0, count = 0
        for y in 560..<640 { for x in 1330..<1380 { mean += Int(rgb.pixels[(y * 1600 + x) * 4]); count += 1 } }
        let average = mean / count
        #expect(brightest >= 228, "Die Füllung ist so hell wie das Papier (238): \(brightest)")
        #expect(average >= 215, "Auch im Mittel kein grauer Fleck: \(average)")
    }

    @Test func removalWorksWhenTheMaskHasAnotherResolutionThanTheImage() throws {
        var c = bookPage()
        c.ellipse(cx: 160, cy: 500, rx: 45, ry: 40, skin)
        let mask = try #require(HandDetector.detect(in: c.image(), page: pageQuad)?.mask)
        // Dasselbe Bild in doppelter Größe, dieselbe Maske.
        var big = Canvas(width: 1600, height: 1200, fill: cloth)
        big.rect(200, 120, 1400, 1080, paper)
        big.ellipse(cx: 320, cy: 1000, rx: 90, ry: 80, skin)
        let cleaned = try #require(HandRemover.apply(to: big.image(), mask: mask))
        #expect(cleaned.width == 1600 && cleaned.height == 1200)
        let rgb = try #require(RGBBitmap(cleaned, width: 1600))
        let i = (1000 * 1600 + 320) * 4
        #expect(rgb.pixels[i] > 210, "Auch bei anderer Auflösung ist der Daumen weg: \(rgb.pixels[i])")
    }

    @Test func anEmptyMaskReturnsTheImageUnchanged() throws {
        let c = bookPage()
        let empty = try #require(HandMask(width: 10, height: 10, cells: [UInt8](repeating: 0, count: 100)))
        let result = try #require(HandRemover.apply(to: c.image(), mask: empty))
        #expect(result.width == c.width && result.height == c.height)
    }

    @Test func distancesCountStepsToTheNearestSource() {
        var sources = [Bool](repeating: false, count: 5 * 3)
        sources[1 * 5 + 0] = true
        let d = HandRemover.distances(from: sources, width: 5, height: 3)
        #expect(d[1 * 5 + 0] == 0 && d[1 * 5 + 1] == 1 && d[1 * 5 + 4] == 4 && d[0 * 5 + 4] == 5)
    }

    // MARK: Als Korrektur

    @Test func correctionsWrittenBeforeHandRemovalExistedStillLoad() throws {
        // So sah eine gespeicherte Korrektur vor der Handentfernung aus: ohne den Schlüssel `handRemoval`.
        let old = """
        {"enabled":true,"revision":3,"version":1,
         "crop":{"enabled":true,"source":"automatic","confidence":0.9},
         "rotation":{"degrees":1.5,"enabled":true,"source":"manual"}}
        """
        let decoded = try JSONDecoder().decode(Corrections.self, from: Data(old.utf8))
        #expect(decoded.rotation.degrees == 1.5 && decoded.revision == 3)
        #expect(decoded.handRemoval == HandRemovalCorrection(), "Ohne Eintrag: keine Hände entfernen")
        #expect(!decoded.handRemoval.hasMask)
    }

    @Test func handRemovalRoundTripsWithItsMask() throws {
        var c = bookPage()
        c.ellipse(cx: 130, cy: 560, rx: 60, ry: 70, skin)
        let mask = try #require(HandDetector.detect(in: c.image())?.mask)
        var corrections = Corrections()
        corrections.handRemoval = HandRemovalCorrection(enabled: true, source: .automatic, confidence: 1, mask: mask.pngData())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let decoded = try JSONDecoder().decode(Corrections.self, from: encoder.encode(corrections))
        #expect(decoded == corrections)
        #expect(HandMask(pngData: try #require(decoded.handRemoval.mask)) == mask)
    }

    @Test func switchingHandRemovalMakesItManualAndCountsARevision() {
        var corrections = Corrections()
        corrections.handRemoval = HandRemovalCorrection(enabled: true, source: .automatic, confidence: 1, mask: Data([1]))
        corrections.setHandRemovalEnabled(false)
        #expect(!corrections.handRemoval.enabled && corrections.handRemoval.source == .manual && corrections.revision == 1)
        #expect(corrections.handRemoval.mask == Data([1]), "Die Maske bleibt, man kann wieder einschalten")
    }

    @Test func theRendererRemovesHandsOnlyWhenEnabled() throws {
        var c = bookPage()
        c.ellipse(cx: 160, cy: 500, rx: 45, ry: 40, skin)
        c.ellipse(cx: 160, cy: 580, rx: 50, ry: 50, skin)
        let mask = try #require(HandDetector.detect(in: c.image())?.mask)
        func redAt(_ image: CGImage, x: Int, y: Int) throws -> Int {
            let rgb = try #require(RGBBitmap(image, width: image.width))
            return Int(rgb.pixels[(y * image.width + x) * 4 + 2])   // Blau: Haut ist hier niedrig, Papier hoch
        }
        var on = Corrections(); on.handRemoval = HandRemovalCorrection(enabled: true, source: .automatic, confidence: 1, mask: mask.pngData())
        var off = on; off.handRemoval.enabled = false
        var master = on; master.enabled = false

        let removed = try #require(CorrectionRenderer.render(c.image(), corrections: on))
        let kept = try #require(CorrectionRenderer.render(c.image(), corrections: off))
        let masterOff = try #require(CorrectionRenderer.render(c.image(), corrections: master))
        #expect(try redAt(removed, x: 160, y: 500) > 190, "Eingeschaltet: der Daumen ist weg")
        #expect(try redAt(kept, x: 160, y: 500) < 150, "Ausgeschaltet: der Daumen bleibt")
        #expect(try redAt(masterOff, x: 160, y: 500) < 150, "Hauptschalter aus: nichts wird verändert")
    }

    // MARK: In der Analyse

    @Test func imageAnalysisFindsHandsAndTurnsThemIntoACorrection() throws {
        var c = bookPage()
        c.ellipse(cx: 130, cy: 580, rx: 60, ry: 70, skin)
        let analysis = ImageAnalyzer.analyze(c.image())
        let hands = try #require(analysis.hands)
        #expect(hands.regions >= 1)
        let corrections = ImageAnalyzer.corrections(from: analysis)
        #expect(corrections.handRemoval.enabled, "Sicher erkannt: wird angewendet")
        #expect(corrections.handRemoval.source == .automatic)
        #expect(corrections.handRemoval.hasMask)
    }

    @Test func imageAnalysisWithoutHandsLeavesTheCorrectionAlone() {
        let analysis = ImageAnalyzer.analyze(bookPage().image())
        #expect(analysis.hands == nil)
        #expect(ImageAnalyzer.corrections(from: analysis).handRemoval == HandRemovalCorrection())
    }

    @Test func bookAnalysisGivesBothPagesTheSameHandMask() throws {
        var c = Canvas(width: 1200, height: 800, fill: cloth)
        c.rect(100, 80, 1100, 720, paper)
        c.ellipse(cx: 160, cy: 760, rx: 60, ry: 70, skin)
        let analysis = BookAnalyzer.analyze(c.image())
        #expect(analysis.hands != nil)
        let pages = BookAnalyzer.corrections(from: analysis)
        #expect(pages.left.handRemoval.hasMask && pages.right.handRemoval.hasMask)
        #expect(pages.left.handRemoval.mask == pages.right.handRemoval.mask)
        #expect(pages.left.handRemoval.enabled)
    }
}
