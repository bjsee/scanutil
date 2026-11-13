import CoreGraphics
import CoreImage
import Foundation

/// Ergebnis der Analyse einer Doppelseite.
public struct BookAnalysis: Equatable, Sendable {
    /// Rand der ganzen Doppelseite, falls erkannt und plausibel.
    public let outer: DocumentDetection?
    public let gutter: Gutter?
    public let leftSkew: SkewEstimate?
    public let rightSkew: SkewEstimate?
    /// Zuschnitt der linken und der rechten Seite. Ohne erkannten Rand oder Falz sind es die Hälften des ganzen Bildes.
    public let leftQuad: Quad
    public let rightQuad: Quad
    public let warnings: [String]
    /// Hände, Daumen und Daumen-Marker auf der Doppelseite. Für die Erkennung von Rand und Falz sind sie herausgenommen.
    public let hands: HandDetection?
}

/// Teilt eine aufgeschlagene Doppelseite am Falz in zwei Seiten und misst deren Schräglage getrennt.
public enum BookAnalyzer {
    private static let workingSize = 2000.0
    private static let context = CIContext()

    public static func analyze(_ original: CGImage) -> BookAnalysis {
        var warnings: [String] = []
        var working = downscaled(original, maxDimension: workingSize)

        // Zuerst die Hände und Daumen-Marker herausnehmen: Sie stören die Randerkennung von Vision und verfälschen den Falz.
        var hands = HandDetector.detect(in: working)
        if let found = hands, let cleaned = HandRemover.apply(to: working, mask: found.mask) { working = cleaned }

        // Rand der Doppelseite. Erkennt Vision nur eine der beiden Seiten, ist das Ergebnis hochkant und wird verworfen.
        var outer = DocumentDetector.detect(in: working)
        if let candidate = outer, !isPlausibleSpread(candidate) {
            warnings.append(candidate.plausibility < 0.5
                ? "Die erkannten Ecken der Doppelseite sind unplausibel."
                : "Es wurde wohl nur eine Seite statt der Doppelseite erkannt.")
            outer = nil
        }
        if outer == nil, warnings.isEmpty { warnings.append("Der Rand der Doppelseite wurde nicht erkannt.") }
        // Die Außenkanten rücken nach innen, bis dort Papier liegt: ohne Einbandstreifen, Tuch und Schatten am Rand.
        let outerQuad = outer.map { EdgeRefiner.refine($0.quad, in: working) } ?? .full
        // Zweiter Durchgang mit bekanntem Seitenrand: findet auch Daumen und Marker, die den Bildrand nicht berühren.
        if let page = outer?.quad, let more = HandDetector.detect(in: downscaled(original, maxDimension: workingSize), page: page) {
            hands = HandDetector.union(hands, more)
        }

        // Falz in der Mitte des Buchs suchen.
        let box = boundingBox(of: outerQuad)
        let centerX = (box.minX + box.maxX) / 2, halfWindow = (box.maxX - box.minX) * 0.15
        let height = box.maxY - box.minY
        let gutter = GutterDetector.detect(
            in: working,
            xRange: max(0, centerX - halfWindow)...min(1, centerX + halfWindow),
            yRange: (box.minY + 0.1 * height)...(box.maxY - 0.1 * height)
        )
        if gutter == nil { warnings.append("Der Falz wurde nicht gefunden, die Seiten sind in der Mitte geteilt.") }
        else if let g = gutter, g.confidence < Corrections.defaultConfidenceThreshold { warnings.append("Der Falz ist unsicher.") }

        let (left, right) = gutter.map { split(outerQuad, at: $0) }
            ?? (SpreadHalves.half(of: outerQuad, left: true), SpreadHalves.half(of: outerQuad, left: false))

        let leftSkew = skew(of: working, quad: left)
        let rightSkew = skew(of: working, quad: right)
        if leftSkew == nil || rightSkew == nil { warnings.append("Die Schräglage einer Seite konnte nicht gemessen werden.") }
        else if let l = leftSkew, let r = rightSkew, min(l.confidence, r.confidence) < Corrections.defaultConfidenceThreshold {
            warnings.append("Die Schräglage einer Seite ist unsicher.")
        }
        return BookAnalysis(outer: outer, gutter: gutter, leftSkew: leftSkew, rightSkew: rightSkew,
                            leftQuad: left, rightQuad: right, warnings: warnings, hands: hands)
    }

    /// Aus der Analyse werden Korrekturen je Seite. Sichere Ergebnisse sind aktiv, unsichere nur vorgeschlagen.
    /// Die Sicherheit des Zuschnitts ist die schwächere von Rand und Falz, ohne Rand zählt nur der Falz.
    public static func corrections(from analysis: BookAnalysis,
                                   threshold: Double = Corrections.defaultConfidenceThreshold) -> (left: Corrections, right: Corrections) {
        let cropConfidence = min(analysis.outer?.plausibility ?? 1, analysis.gutter?.confidence ?? 0)
        // Mit gefundenem Falz wird zugeschnitten, auch bei niedriger Sicherheit. Die Teilung ist bei einer Doppelseite ohnehin nötig,
        // und ein unsicherer Zuschnitt war an echten Büchern richtig, die Bildhälfte mit Tuch dagegen nie: Eine flache Schattenlinie
        // (leere Seite, kaum Falz) drückt die Sicherheit, ohne dass die Lage falsch wäre. Die Warnung „Falz unsicher“ bleibt.
        let cropConfident = analysis.gutter != nil
        func make(quad: Quad, skew: SkewEstimate?) -> Corrections {
            var result = Corrections()
            result.tone = ToneCorrection(enabled: true, source: .automatic)
            result.crop = CropCorrection(quad: quad, enabled: cropConfident, source: .automatic, confidence: cropConfidence)
            if let s = skew {
                result.rotation = RotationCorrection(degrees: s.degrees, enabled: s.confidence >= threshold, source: .automatic, confidence: s.confidence)
            }
            // Beide Seiten tragen dieselbe Maske: jede schneidet danach ihren eigenen Ausschnitt.
            if let hands = analysis.hands {
                result.handRemoval = HandRemovalCorrection(enabled: hands.confidence >= threshold, source: .automatic,
                                                           confidence: hands.confidence, mask: hands.mask.pngData())
            }
            return result
        }
        return (make(quad: analysis.leftQuad, skew: analysis.leftSkew), make(quad: analysis.rightQuad, skew: analysis.rightSkew))
    }

    /// Teilt das Viereck an der Falzgeraden. Die Schnittpunkte liegen auf der oberen und der unteren Kante.
    public static func split(_ quad: Quad, at gutter: Gutter) -> (left: Quad, right: Quad) {
        // Schnitt der Geraden x = xTop + s·y mit der Kante von `a` nach `b`.
        func cut(_ a: NormalizedPoint, _ b: NormalizedPoint) -> NormalizedPoint {
            let s = gutter.slope, dx = b.x - a.x, dy = b.y - a.y
            let denominator = dx - s * dy
            var t = abs(denominator) > 1e-9 ? (gutter.xTop + s * a.y - a.x) / denominator : 0.5
            t = min(0.85, max(0.15, t))
            return NormalizedPoint(x: a.x + dx * t, y: a.y + dy * t)
        }
        let top = cut(quad.topLeft, quad.topRight), bottom = cut(quad.bottomLeft, quad.bottomRight)
        return (Quad(topLeft: quad.topLeft, topRight: top, bottomRight: bottom, bottomLeft: quad.bottomLeft),
                Quad(topLeft: top, topRight: quad.topRight, bottomRight: quad.bottomRight, bottomLeft: bottom))
    }

    /// Eine Doppelseite ist breiter als hoch und ein plausibles Viereck.
    static func isPlausibleSpread(_ detection: DocumentDetection) -> Bool {
        guard detection.plausibility >= 0.5 else { return false }
        let box = boundingBox(of: detection.quad)
        return (box.maxX - box.minX) > (box.maxY - box.minY)
    }

    private static func boundingBox(of quad: Quad) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let xs = [quad.topLeft.x, quad.topRight.x, quad.bottomRight.x, quad.bottomLeft.x]
        let ys = [quad.topLeft.y, quad.topRight.y, quad.bottomRight.y, quad.bottomLeft.y]
        return (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
    }

    /// Schräglage einer Seite, gemessen auf der ausgeschnittenen und entzerrten Seite.
    private static func skew(of image: CGImage, quad: Quad) -> SkewEstimate? {
        var crop = Corrections(crop: CropCorrection(quad: quad, enabled: true))
        crop.enabled = true
        guard let page = CorrectionRenderer.render(image, corrections: crop) else { return nil }
        return SkewEstimator.estimateAveraged(page)
    }

    private static func downscaled(_ image: CGImage, maxDimension: Double) -> CGImage {
        let longest = Double(max(image.width, image.height))
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(ci, from: ci.extent) ?? image
    }
}

/// Hälften eines Vierecks, ohne Falz.
enum SpreadHalves {
    static func half(of quad: Quad, left: Bool) -> Quad {
        func mid(_ a: NormalizedPoint, _ b: NormalizedPoint) -> NormalizedPoint {
            NormalizedPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let top = mid(quad.topLeft, quad.topRight), bottom = mid(quad.bottomLeft, quad.bottomRight)
        return left
            ? Quad(topLeft: quad.topLeft, topRight: top, bottomRight: bottom, bottomLeft: quad.bottomLeft)
            : Quad(topLeft: top, topRight: quad.topRight, bottomRight: quad.bottomRight, bottomLeft: bottom)
    }
}
