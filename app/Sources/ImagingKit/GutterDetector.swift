import CoreGraphics
import Foundation

/// Der Falz einer aufgeschlagenen Doppelseite als Gerade durch das Bild, in normierten Bildkoordinaten
/// (x und y von 0 bis 1, Ursprung oben links). Die Gerade ist über die ganze Bildhöhe fortgesetzt.
public struct Gutter: Equatable, Sendable {
    /// Lage bei y = 0.
    public let xTop: Double
    /// Lage bei y = 1.
    public let xBottom: Double
    /// Sicherheit von 0 bis 1: die schwächste von drei Größen (Anteil brauchbarer Bänder, Tiefe des Tals, Streuung der Geraden).
    public let confidence: Double

    public init(xTop: Double, xBottom: Double, confidence: Double) {
        self.xTop = xTop
        self.xBottom = xBottom
        self.confidence = confidence
    }

    /// Lage der Geraden in der Höhe `y`.
    public func x(atY y: Double) -> Double { xTop + (xBottom - xTop) * y }

    /// Steigung dx/dy.
    public var slope: Double { xBottom - xTop }
}

/// Findet den Falz im Schatten zwischen zwei Seiten. Der Falz ist dort, wo das Papier über die Höhe hinweg am dunkelsten ist.
///
/// Je Bildband wird für jede Spalte ein heller Perzentilwert gebildet. Textzeilen haben darauf kaum Einfluss, der
/// Schatten im Falz bleibt in jeder Zeile dunkel. Das Minimum des Profils ist die Lage des Falzes im Band,
/// durch die Lagen aller Bänder wird eine Gerade gelegt.
public enum GutterDetector {
    /// Anzahl der waagerechten Bänder.
    static let bandCount = 10
    /// Mindesttiefe des Tals gegenüber dem Median des Suchfensters, in Grauwerten (von 255).
    static let minimumDepth = 5.0
    /// Mindestzahl brauchbarer Bänder.
    static let minimumBands = 4

    /// - Parameters:
    ///   - xRange: Suchfenster in x, normiert. Der Falz liegt in der Nähe der Mitte des Buchs.
    ///   - yRange: Höhenbereich, in dem gemessen wird, normiert. Die Ränder oben und unten bleiben außen vor.
    public static func detect(in image: CGImage, xRange: ClosedRange<Double> = 0.35...0.65,
                              yRange: ClosedRange<Double> = 0.1...0.9) -> Gutter? {
        guard let gray = GrayBitmap(image, maxDimension: 1000) else { return nil }
        return detect(gray, xRange: xRange, yRange: yRange)
    }

    static func detect(_ gray: GrayBitmap, xRange: ClosedRange<Double>, yRange: ClosedRange<Double>) -> Gutter? {
        let x0 = max(0, Int(xRange.lowerBound * Double(gray.width)))
        let x1 = min(gray.width, Int(xRange.upperBound * Double(gray.width)))
        guard x1 - x0 >= 16 else { return nil }
        let yStart = Int(yRange.lowerBound * Double(gray.height)), yEnd = Int(yRange.upperBound * Double(gray.height))
        let bandHeight = (yEnd - yStart) / bandCount
        guard bandHeight >= 4 else { return nil }

        var samples: [(y: Double, x: Double, depth: Double)] = []
        for band in 0..<bandCount {
            let rows = (yStart + band * bandHeight)..<(yStart + (band + 1) * bandHeight)
            guard let valley = valley(in: gray, columns: x0..<x1, rows: rows) else { continue }
            let y = Double(rows.lowerBound + rows.upperBound) / 2 / Double(gray.height)
            samples.append((y, Double(valley.column) / Double(gray.width), valley.depth / 255))
        }
        guard samples.count >= minimumBands else { return nil }

        // Gerade durch die Lagen, einmal ohne Ausreißer wiederholt.
        var inliers = samples
        var fit = leastSquares(inliers.map { ($0.y, $0.x) })
        let residuals = inliers.map { abs($0.x - (fit.intercept + fit.slope * $0.y)) }
        let mad = residuals.sorted()[residuals.count / 2]
        let limit = max(3 * mad, 0.01)
        let kept = inliers.enumerated().filter { residuals[$0.offset] <= limit }.map(\.element)
        if kept.count >= minimumBands, kept.count < inliers.count {
            inliers = kept
            fit = leastSquares(inliers.map { ($0.y, $0.x) })
        }
        guard inliers.count >= minimumBands else { return nil }

        let rms = (inliers.map { pow($0.x - (fit.intercept + fit.slope * $0.y), 2) }.reduce(0, +) / Double(inliers.count)).squareRoot()
        let medianDepth = inliers.map(\.depth).sorted()[inliers.count / 2]
        let usable = Double(inliers.count) / Double(bandCount)
        let depthScore = min(1, medianDepth / 0.10)
        let spreadScore = max(0, 1 - rms / 0.02)
        var confidence = min(usable, depthScore, spreadScore)

        let xTop = fit.intercept, xBottom = fit.intercept + fit.slope
        // Ein Falz, der quer durchs Bild läuft, ist keiner.
        if abs(xBottom - xTop) > 0.3 { confidence = 0 }
        return Gutter(xTop: xTop, xBottom: xBottom, confidence: confidence)
    }

    /// Radius der Umgebung, gegen die ein Tal gemessen wird, als Anteil der Bildbreite.
    static let baselineRadiusShare = 0.04

    /// Tiefste Stelle des Profils in einem Band, oder `nil`, wenn dort kein Tal liegt.
    ///
    /// Gemessen wird gegen die Umgebung (gleitender Median), nicht gegen das ganze Fenster: Ein Helligkeitsverlauf über das Bild
    /// (Licht von einer Seite, Papier das zum Rand hin dunkler wird) macht sonst die Fensterkante zum „dunkelsten“ Punkt und
    /// übertönt einen flachen Falz.
    private static func valley(in gray: GrayBitmap, columns: Range<Int>, rows: Range<Int>) -> (column: Int, depth: Double)? {
        let reach = max(4, Int(baselineRadiusShare * Double(gray.width)))
        let lo = max(0, columns.lowerBound - reach), hi = min(gray.width, columns.upperBound + reach)
        // Heller Perzentilwert je Spalte: Text (dunkel, dünn) fällt heraus, Schatten (dunkel in jeder Zeile) bleibt.
        var profile = [Double](repeating: 0, count: hi - lo)
        var values = [UInt8](repeating: 0, count: rows.count)
        for (i, x) in (lo..<hi).enumerated() {
            for (j, y) in rows.enumerated() { values[j] = gray.pixels[y * gray.width + x] }
            values.sort()
            profile[i] = Double(values[min(values.count - 1, values.count * 85 / 100)])
        }
        // Glätten, damit Papierkörnung nicht das Minimum bestimmt.
        let radius = 3
        let smooth = profile.indices.map { i -> Double in
            let a = max(0, i - radius), b = min(profile.count - 1, i + radius)
            return profile[a...b].reduce(0, +) / Double(b - a + 1)
        }
        // Abstand zur Umgebung, nur im Suchfenster.
        let offset = columns.lowerBound - lo
        var dips = [Double](repeating: 0, count: columns.count)
        for i in 0..<columns.count {
            let c = offset + i
            let a = max(0, c - reach), b = min(smooth.count - 1, c + reach)
            let around = smooth[a...b].sorted()[(b - a + 1) / 2]
            dips[i] = around - smooth[c]
        }
        guard let maxIndex = dips.indices.max(by: { dips[$0] < dips[$1] }) else { return nil }
        // Liegt das Maximum am Rand des Fensters, fällt das Profil nur ab: dort ist kein Tal, sondern eine Kante.
        let margin = max(2, dips.count / 20)
        guard maxIndex >= margin, maxIndex < dips.count - margin else { return nil }
        let depth = dips[maxIndex]
        guard depth >= minimumDepth else { return nil }
        return (columns.lowerBound + maxIndex, depth)
    }

    private static func leastSquares(_ points: [(Double, Double)]) -> (intercept: Double, slope: Double) {
        let n = Double(points.count)
        let sy = points.map(\.0).reduce(0, +), sx = points.map(\.1).reduce(0, +)
        let syy = points.map { $0.0 * $0.0 }.reduce(0, +), syx = points.map { $0.0 * $0.1 }.reduce(0, +)
        let denominator = n * syy - sy * sy
        guard abs(denominator) > 1e-12 else { return (sx / n, 0) }
        let slope = (n * syx - sy * sx) / denominator
        return ((sx - slope * sy) / n, slope)
    }
}
