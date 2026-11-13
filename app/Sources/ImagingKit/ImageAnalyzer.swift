import CoreGraphics
import CoreImage
import Foundation

/// Ergebnis der automatischen Analyse eines Originals.
public struct Analysis: Equatable, Sendable {
    public let detection: DocumentDetection?
    public let skew: SkewEstimate?
    public let warnings: [String]
    /// Hände, Daumen und Daumen-Marker, die erkannt wurden. Sie sind für die Erkennung des Randes und der Schräglage
    /// schon herausgenommen.
    public let hands: HandDetection?

    public init(detection: DocumentDetection?, skew: SkewEstimate?, warnings: [String], hands: HandDetection? = nil) {
        self.detection = detection
        self.skew = skew
        self.warnings = warnings
        self.hands = hands
    }
}

/// Verbindet Dokumenterkennung und Winkelmessung und macht daraus Korrekturen.
/// Zweifelhafte Ergebnisse werden nicht angewendet, sondern als Vorschlag markiert (`Corrections.needsReview`).
public enum ImageAnalyzer {
    /// Längste Seite des verkleinerten Arbeitsbildes.
    private static let workingSize = 2000.0
    private static let context = CIContext()

    public static func analyze(_ original: CGImage) -> Analysis {
        var warnings: [String] = []
        var working = downscaled(original, maxDimension: workingSize)

        // Zuerst die Hände und Daumen-Marker: Sie bringen die Dokumenterkennung von Vision durcheinander (an einem Scan mit
        // Händen fand sie als „Dokument“ ein Dreieck). Danach arbeiten Rand und Schräglage auf dem bereinigten Bild.
        var hands = HandDetector.detect(in: working)
        if let found = hands, let cleaned = HandRemover.apply(to: working, mask: found.mask) { working = cleaned }

        let detection = DocumentDetector.detect(in: working)
        // Zweiter Durchgang mit bekanntem Seitenrand: findet auch Marker und Daumen, die den Bildrand nicht berühren.
        if let page = detection?.quad, let more = HandDetector.detect(in: downscaled(original, maxDimension: workingSize), page: page) {
            hands = HandDetector.union(hands, more)
        }
        if detection == nil { warnings.append("Es wurde kein Dokument erkannt.") }
        else if let d = detection, d.plausibility < 0.5 { warnings.append("Die erkannten Ecken sind unplausibel.") }

        // Winkel auf dem zugeschnittenen, entzerrten Dokument messen, nicht auf dem Rohbild mit Hintergrund.
        var flat = working
        if let detection, detection.plausibility >= 0.5 {
            var crop = Corrections(crop: CropCorrection(quad: detection.quad, enabled: true))
            crop.enabled = true
            if let rendered = CorrectionRenderer.render(working, corrections: crop) { flat = rendered }
        }
        let skew = SkewEstimator.estimate(flat)
        if skew == nil { warnings.append("Die Schräglage konnte nicht gemessen werden (zu wenig Text).") }
        else if let s = skew, s.confidence < Corrections.defaultConfidenceThreshold { warnings.append("Die Schräglage ist unsicher.") }
        return Analysis(detection: detection, skew: skew, warnings: warnings, hands: hands)
    }

    /// Aus einer Analyse werden Korrekturen: sichere Ergebnisse sind aktiv, unsichere nur vorgeschlagen.
    public static func corrections(from analysis: Analysis, threshold: Double = Corrections.defaultConfidenceThreshold) -> Corrections {
        var result = Corrections()
        // Papier aufhellen gilt für jede Aufnahme von Papier, unabhängig von der Sicherheit der Erkennung.
        result.tone = ToneCorrection(enabled: true, source: .automatic)
        if let d = analysis.detection {
            let confident = d.plausibility >= threshold
            result.crop = CropCorrection(quad: d.quad, enabled: confident, source: .automatic, confidence: d.plausibility)
        }
        if let s = analysis.skew {
            let confident = s.confidence >= threshold
            result.rotation = RotationCorrection(degrees: s.degrees, enabled: confident, source: .automatic, confidence: s.confidence)
        }
        if let hands = analysis.hands {
            result.handRemoval = HandRemovalCorrection(enabled: hands.confidence >= threshold, source: .automatic,
                                                       confidence: hands.confidence, mask: hands.mask.pngData())
        }
        return result
    }

    private static func downscaled(_ image: CGImage, maxDimension: Double) -> CGImage {
        let longest = Double(max(image.width, image.height))
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(ci, from: ci.extent) ?? image
    }
}
