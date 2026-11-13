import CoreGraphics
import Foundation

/// Ergebnis einer Winkelmessung.
public struct SkewEstimate: Equatable, Sendable {
    /// Drehung im Uhrzeigersinn in Grad, die den Text waagerecht stellt.
    public let degrees: Double
    /// Sicherheit von 0 bis 1.
    public let confidence: Double
    /// Rohwert: wie weit sich der beste Winkel vom Durchschnitt aller Winkel abhebt (in Standardabweichungen).
    public let contrast: Double
    /// Rohwert: bester Wert geteilt durch den Median aller Winkel. Bei Rauschen nahe 1.
    public let peakRatio: Double

    public init(degrees: Double, confidence: Double, contrast: Double, peakRatio: Double = 1) {
        self.degrees = degrees
        self.confidence = confidence
        self.contrast = contrast
        self.peakRatio = peakRatio
    }
}

/// Misst die Schräglage von Textzeilen über ein Projektionsprofil.
///
/// Für viele Drehwinkel werden die dunklen Pixel auf die Zeilenachse projiziert. Liegen die Textzeilen waagerecht,
/// ist das Profil am zackigsten (größte Varianz). Vision liefert dafür keine brauchbaren Kleinwinkel,
/// siehe docs/spike-apple-vision.adoc.
public enum SkewEstimator {
    public static let searchRange: ClosedRange<Double> = -15...15

    /// Maximale Zahl dunkler Punkte, die in die Messung eingehen.
    private static let maxPoints = 250_000

    public static func estimate(_ image: CGImage) -> SkewEstimate? {
        guard let gray = GrayBitmap(image, maxDimension: 1000) else { return nil }
        return estimate(gray)
    }

    /// Anzahl der Höhenbänder für die gemittelte Messung.
    static let averagingBands = 3
    /// Ein Band, dessen Winkel so weit vom Wert der ganzen Seite abweicht, gilt als Ausreißer (Überschrift, Zeichnung, Fleck).
    static let bandOutlierDegrees = 3.0

    /// Schräglage einer Seite aus mehreren Höhenbändern, gemittelt.
    ///
    /// Eine gewölbte Buchseite hat keine einheitliche Schräglage: Die Zeilen fächern sich über die Höhe auf (gemessen an echten Seiten:
    /// oben 0°, in der Mitte −0,9°, unten −1,3° bis −2,2°). Das Projektionsprofil über die ganze Seite gewichtet dabei jedes
    /// dunkle Pixel, also dichte Textstellen, und kippt zu einem Ende hin. Der Mittelwert der Bänder verteilt die Abweichung
    /// gleichmäßig; von Hand gewählt lag der Wert in den Beispielen auch dort. Bei ebenen Seiten ändert sich nichts.
    public static func estimateAveraged(_ image: CGImage) -> SkewEstimate? {
        guard let whole = estimate(image) else { return nil }
        let h = image.height
        guard h >= averagingBands * 60 else { return whole }
        var angles: [Double] = []
        for band in 0..<averagingBands {
            let top = h * band / averagingBands, bottom = h * (band + 1) / averagingBands
            guard let part = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: bottom - top)),
                  let measured = estimate(part), measured.confidence >= Corrections.defaultConfidenceThreshold,
                  abs(measured.degrees - whole.degrees) <= bandOutlierDegrees else { continue }
            angles.append(measured.degrees)
        }
        guard angles.count >= 2 else { return whole }
        let mean = angles.reduce(0, +) / Double(angles.count)
        let rounded = (mean / 0.05).rounded() * 0.05
        return SkewEstimate(degrees: rounded, confidence: whole.confidence, contrast: whole.contrast, peakRatio: whole.peakRatio)
    }

    static func estimate(_ gray: GrayBitmap) -> SkewEstimate? {
        let threshold = otsuThreshold(gray.pixels)
        // Ränder weglassen: Schatten, Falz und Papierkante täuschen sonst eine Linie vor.
        let marginX = gray.width / 10, marginY = gray.height / 10
        var points: [(Float, Float)] = []
        points.reserveCapacity(maxPoints)
        var dark = 0
        for y in marginY..<(gray.height - marginY) {
            for x in marginX..<(gray.width - marginX) where gray.pixels[y * gray.width + x] < threshold { dark += 1 }
        }
        guard dark > 200 else { return nil }
        let sampling = max(1, dark / maxPoints)
        var counter = 0
        for y in marginY..<(gray.height - marginY) {
            for x in marginX..<(gray.width - marginX) where gray.pixels[y * gray.width + x] < threshold {
                counter += 1
                if counter % sampling == 0 { points.append((Float(x), Float(y))) }
            }
        }

        let diagonal = Int((Double(gray.width * gray.width + gray.height * gray.height)).squareRoot()) + 2
        var histogram = [Float](repeating: 0, count: diagonal * 2)

        func score(_ degrees: Double) -> Double {
            let radians = degrees * .pi / 180
            let c = Float(cos(radians)), s = Float(sin(radians))
            for i in histogram.indices { histogram[i] = 0 }
            let offset = Float(diagonal)
            for (x, y) in points {
                // Drehung im Uhrzeigersinn bei nach unten zeigender y-Achse.
                let rotatedY = x * s + y * c
                histogram[Int(rotatedY + offset)] += 1
            }
            var sum: Float = 0, sumSquares: Float = 0
            for v in histogram { sum += v; sumSquares += v * v }
            let n = Float(histogram.count)
            return Double(sumSquares / n - (sum / n) * (sum / n))
        }

        // Grob in halben Graden, dann fein um das Maximum.
        let coarseAngles = Swift.stride(from: searchRange.lowerBound, through: searchRange.upperBound, by: 0.5)
        let coarse: [(Double, Double)] = coarseAngles.map { ($0, score($0)) }
        guard let best = coarse.max(by: { $0.1 < $1.1 }) else { return nil }
        let fineAngles = Swift.stride(from: best.0 - 0.6, through: best.0 + 0.6, by: 0.05)
        let fine: [(Double, Double)] = fineAngles.map { ($0, score($0)) }
        guard let refined = fine.max(by: { $0.1 < $1.1 }) else { return nil }

        let values = coarse.map(\.1)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let deviation = variance.squareRoot()
        let median = values.sorted()[values.count / 2]
        let peakRatio = median > 0 ? refined.1 / median : 1
        guard deviation > 0 else { return SkewEstimate(degrees: refined.0, confidence: 0, contrast: 0, peakRatio: peakRatio) }
        let contrast = (best.1 - mean) / deviation
        // Sicherheit aus dem Spitzenverhältnis. Gemessen an echten Scans und Gegenbeispielen:
        // Rauschen, Holzfoto und Flecken liegen bei 1,02 bis 1,10, Buch und Zeitung bei 1,3 bis 1,4,
        // synthetische Seiten bei über 2. Der Kontrast in Standardabweichungen taugte nicht,
        // weil schon Rauschen bei 61 geprüften Winkeln etwa 2,3 erreicht.
        // Die Eichung beruht auf wenigen Beispielen und gehört mit mehr Vorlagen überprüft.
        let confidence = min(1, max(0, (peakRatio - 1.1) / 0.3))
        return SkewEstimate(degrees: refined.0, confidence: confidence, contrast: contrast, peakRatio: peakRatio)
    }

    /// Schwellwert nach Otsu: trennt Schrift vom Papier.
    static func otsuThreshold(_ pixels: [UInt8]) -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        for p in pixels { histogram[Int(p)] += 1 }
        let total = pixels.count
        var sumAll = 0.0
        for i in 0..<256 { sumAll += Double(i * histogram[i]) }
        var sumBackground = 0.0, weightBackground = 0, best = 0.0, threshold = 128
        for t in 0..<256 {
            weightBackground += histogram[t]
            if weightBackground == 0 { continue }
            let weightForeground = total - weightBackground
            if weightForeground == 0 { break }
            sumBackground += Double(t * histogram[t])
            let meanBackground = sumBackground / Double(weightBackground)
            let meanForeground = (sumAll - sumBackground) / Double(weightForeground)
            let between = Double(weightBackground) * Double(weightForeground) * (meanBackground - meanForeground) * (meanBackground - meanForeground)
            if between > best { best = between; threshold = t }
        }
        return UInt8(threshold)
    }
}

/// Graustufenbild im Speicher.
struct GrayBitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage, maxDimension: Int) {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var data = [UInt8](repeating: 0, count: w * h)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        pixels = data
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}
