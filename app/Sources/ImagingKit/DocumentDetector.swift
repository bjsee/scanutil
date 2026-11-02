import CoreGraphics
import Foundation
import Vision

/// Erkennt den Rand des Dokuments mit Apple Vision.
public struct DocumentDetection: Equatable, Sendable {
    public let quad: Quad
    /// Von Vision gemeldet. In allen bisherigen Läufen lag der Wert bei 0,99, er ist wenig aussagekräftig.
    public let reportedConfidence: Double
    /// Eigene Plausibilitätsprüfung der Ecken von 0 bis 1.
    public let plausibility: Double
}

public enum DocumentDetector {
    /// Längste Seite des Bildes, auf dem Vision arbeitet. Größer bringt nichts außer Zeit.
    private static let analysisSize = 2000

    public static func detect(in image: CGImage) -> DocumentDetection? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first else { return nil }
        // Vision: Ursprung unten links. Umrechnung auf oben links.
        func point(_ p: CGPoint) -> NormalizedPoint { NormalizedPoint(x: Double(p.x), y: 1 - Double(p.y)) }
        let quad = Quad(
            topLeft: point(observation.topLeft), topRight: point(observation.topRight),
            bottomRight: point(observation.bottomRight), bottomLeft: point(observation.bottomLeft)
        )
        return DocumentDetection(quad: quad, reportedConfidence: Double(observation.confidence), plausibility: plausibility(of: quad))
    }

    /// Ein Dokument ist ein nicht zu kleines, konvexes Viereck mit ungefähr rechten Winkeln.
    static func plausibility(of quad: Quad) -> Double {
        let p = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        // Fläche nach Gauß, normiert.
        var area = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            area += a.x * b.y - b.x * a.y
        }
        area = abs(area) / 2
        guard area > 0.05 else { return 0 }
        // Winkel an den Ecken: nahe 90 Grad ist plausibel.
        var worst = 0.0
        for i in 0..<4 {
            let prev = p[(i + 3) % 4], cur = p[i], next = p[(i + 1) % 4]
            let v1 = (prev.x - cur.x, prev.y - cur.y), v2 = (next.x - cur.x, next.y - cur.y)
            let dot = v1.0 * v2.0 + v1.1 * v2.1
            let norm = (v1.0 * v1.0 + v1.1 * v1.1).squareRoot() * (v2.0 * v2.0 + v2.1 * v2.1).squareRoot()
            guard norm > 0 else { return 0 }
            let angle = acos(max(-1, min(1, dot / norm))) * 180 / .pi
            worst = max(worst, abs(angle - 90))
        }
        // 0 Grad Abweichung: 1, ab 35 Grad: 0.
        return max(0, min(1, 1 - worst / 35))
    }
}
