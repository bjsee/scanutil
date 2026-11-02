import CoreGraphics
import CoreImage
import Foundation

/// Ergebnis der automatischen Analyse eines Originals.
public struct Analysis: Equatable, Sendable {
    public let detection: DocumentDetection?
    public let skew: SkewEstimate?
    public let warnings: [String]
}

/// Verbindet Dokumenterkennung und Winkelmessung und macht daraus Korrekturen.
/// Zweifelhafte Ergebnisse werden nicht angewendet, sondern als Vorschlag markiert (`Corrections.needsReview`).
public enum ImageAnalyzer {
    /// Längste Seite des verkleinerten Arbeitsbildes.
    private static let workingSize = 2000.0
    private static let context = CIContext()

    public static func analyze(_ original: CGImage) -> Analysis {
        var warnings: [String] = []
        let working = downscaled(original, maxDimension: workingSize)

        let detection = DocumentDetector.detect(in: working)
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
        return Analysis(detection: detection, skew: skew, warnings: warnings)
    }

    /// Aus einer Analyse werden Korrekturen: sichere Ergebnisse sind aktiv, unsichere nur vorgeschlagen.
    public static func corrections(from analysis: Analysis, threshold: Double = Corrections.defaultConfidenceThreshold) -> Corrections {
        var result = Corrections()
        if let d = analysis.detection {
            let confident = d.plausibility >= threshold
            result.crop = CropCorrection(quad: d.quad, enabled: confident, source: .automatic, confidence: d.plausibility)
        }
        if let s = analysis.skew {
            let confident = s.confidence >= threshold
            result.rotation = RotationCorrection(degrees: s.degrees, enabled: confident, source: .automatic, confidence: s.confidence)
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
