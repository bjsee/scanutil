import CoreGraphics
import Foundation

/// Der Zeilenwinkel einer Seite auf einem groben Raster, in Grad. Positiv wie bei `SkewEstimate`: Ein nach rechts ansteigender Text
/// hat einen positiven Winkel. Gewölbte Buchseiten haben keinen einheitlichen Winkel, die Zeilen fächern sich auf (gemessen an
/// echten Seiten: oben 0°, unten −1° bis −3°). Das Raster hält fest, wo die Zeilen wie laufen.
public struct WarpField: Codable, Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    /// Winkel in Grad, zeilenweise von oben nach unten, je Zeile von links nach rechts.
    public let angles: [Float]

    public init?(columns: Int, rows: Int, angles: [Float]) {
        guard columns >= 1, rows >= 1, angles.count == columns * rows else { return nil }
        self.columns = columns
        self.rows = rows
        self.angles = angles
    }

    /// Das Raster liegt auf diesem Teil der Seite (normiert); die Messfenster sind etwas kleiner als die Seite, damit Rand,
    /// Falz und Schatten nicht mitmessen.
    static let xRange = 0.05...0.95
    static let yRange = 0.08...0.92

    /// Mittelpunkt der Zelle in normierten Koordinaten.
    static func center(column c: Int, of columns: Int) -> Double { xRange.lowerBound + (xRange.upperBound - xRange.lowerBound) * (Double(c) + 0.5) / Double(columns) }
    static func center(row r: Int, of rows: Int) -> Double { yRange.lowerBound + (yRange.upperBound - yRange.lowerBound) * (Double(r) + 0.5) / Double(rows) }

    /// Mittelwert aller Zellen.
    public var mean: Double { angles.isEmpty ? 0 : Double(angles.reduce(0, +)) / Double(angles.count) }
    /// Größter Unterschied zwischen zwei Zellen, in Grad.
    public var spread: Double { Double((angles.max() ?? 0) - (angles.min() ?? 0)) }
    /// Größte Abweichung einer Zelle vom Mittelwert, in Grad.
    public var largestDeviation: Double { angles.map { abs(Double($0) - mean) }.max() ?? 0 }
    /// Ob die Zeilen so unterschiedlich laufen, dass sich das Ausgleichen lohnt, ohne dass es nach Fehlmessung (Bild, Handschrift) aussieht.
    public var isWorthEqualizing: Bool { spread >= DewarpEstimator.minimumSpread && largestDeviation <= DewarpEstimator.maximumDeviation }

    /// Gewichte der Zeilen- bzw. Spaltenmitten zum normierten Ort `t`: bilinear zwischen den beiden nächsten Mitten, außerhalb
    /// der äußersten Mitten gilt deren Wert.
    static func weights(at t: Double, count: Int, center: (Int) -> Double) -> (lower: Int, upper: Int, share: Double) {
        guard count > 1 else { return (0, 0, 0) }
        if t <= center(0) { return (0, 0, 0) }
        if t >= center(count - 1) { return (count - 1, count - 1, 0) }
        for i in 0..<(count - 1) {
            let a = center(i), b = center(i + 1)
            if t <= b { return (i, i + 1, (t - a) / (b - a)) }
        }
        return (count - 1, count - 1, 0)
    }

    /// Winkel an einem Ort der Seite (normiert, Ursprung oben links), bilinear zwischen den Zellmitten.
    public func angle(atX x: Double, y: Double) -> Double {
        let cx = WarpField.weights(at: x, count: columns) { WarpField.center(column: $0, of: columns) }
        let ry = WarpField.weights(at: y, count: rows) { WarpField.center(row: $0, of: rows) }
        func a(_ r: Int, _ c: Int) -> Double { Double(angles[r * columns + c]) }
        let top = a(ry.lower, cx.lower) * (1 - cx.share) + a(ry.lower, cx.upper) * cx.share
        let bottom = a(ry.upper, cx.lower) * (1 - cx.share) + a(ry.upper, cx.upper) * cx.share
        return top * (1 - ry.share) + bottom * ry.share
    }
}

/// Gleicht die Wölbung einer Seite aus: Jede Spalte der Seite wird senkrecht so verschoben, dass die Zeilen überall auf demselben
/// Winkel laufen, dem der Drehung. Wirkt nach dem Zuschnitt und vor der Drehung.
public struct DewarpCorrection: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var source: CorrectionSource
    /// Anteil der Messfenster, in denen der Zeilenwinkel verlässlich gemessen wurde (0 bis 1).
    public var confidence: Double?
    /// Ohne Raster gibt es nichts auszugleichen.
    public var field: WarpField?

    public init(enabled: Bool = false, source: CorrectionSource = .automatic, confidence: Double? = nil, field: WarpField? = nil) {
        self.enabled = enabled
        self.source = source
        self.confidence = confidence
        self.field = field
    }

    public var hasField: Bool { field != nil }

    /// Vermerk „gemessen, aber nicht messbar“ (Bildseite, leere Seite): Sicherheit 0 und kein Raster. Ohne ihn bliebe eine solche
    /// Seite für immer offen.
    public static let notMeasurable = DewarpCorrection(enabled: false, source: .automatic, confidence: 0, field: nil)

    /// Ob eine Messung versucht wurde, mit oder ohne Ergebnis.
    public var wasMeasured: Bool { confidence != nil || field != nil }
}

/// Ergebnis der Messung des Zeilenwinkels auf einem Raster über die Seite.
public struct DewarpEstimate: Equatable, Sendable {
    public let field: WarpField
    /// Anteil der Fenster mit verlässlicher Messung.
    public let reliableShare: Double
    /// Ob sich das Ausgleichen lohnt und sicher genug ist, um es von selbst einzuschalten.
    public var worthApplying: Bool {
        reliableShare >= DewarpEstimator.minimumReliableShare && field.isWorthEqualizing
    }
}

/// Misst den Zeilenwinkel in einem Raster aus Fenstern über die entzerrte (zugeschnittene) Seite.
public enum DewarpEstimator {
    static let columns = 3
    static let rows = 7
    /// Mindestanteil verlässlicher Fenster, damit das Raster etwas taugt.
    static let minimumReliableShare = 0.7
    /// Erst ab diesem Unterschied zwischen den Zellen sieht man etwas (in Grad).
    static let minimumSpread = 0.6
    /// Eine größere Abweichung vom Mittel ist eher eine Fehlmessung (Bild, Handschrift) als eine Wölbung.
    static let maximumDeviation = 6.0
    /// Fenster mit weniger dunklen Punkten (Schrift) werden nicht gemessen.
    static let minimumPoints = 600
    /// Spitzenverhältnis (bester Winkel / Median aller Winkel) ab dem ein Fenster als verlässlich gilt.
    static let minimumPeakRatio = 1.3
    static let searchRange: ClosedRange<Double> = -6...6
    static let maxPoints = 60_000

    public static func estimate(_ page: CGImage) -> DewarpEstimate? {
        guard let gray = GrayBitmap(page, maxDimension: 1000), gray.width >= 60, gray.height >= 120 else { return nil }
        let inner = (0.05...0.95)
        let sample = gray.pixels.enumerated().filter { i, _ in
            let x = Double(i % gray.width) / Double(gray.width), y = Double(i / gray.width) / Double(gray.height)
            return inner.contains(x) && inner.contains(y)
        }.map(\.element)
        let threshold = SkewEstimator.otsuThreshold(sample)

        var values = [Float](repeating: 0, count: columns * rows)
        var known = [Bool](repeating: false, count: columns * rows)
        for r in 0..<rows {
            // Die Fenster überlappen sich etwas: jedes ist um ein Fünftel einer Zelle größer.
            let cellH = (WarpField.yRange.upperBound - WarpField.yRange.lowerBound) / Double(rows)
            let y0 = Int(((WarpField.center(row: r, of: rows) - cellH * 0.7)) * Double(gray.height))
            let y1 = Int(((WarpField.center(row: r, of: rows) + cellH * 0.7)) * Double(gray.height))
            for c in 0..<columns {
                let cellW = (WarpField.xRange.upperBound - WarpField.xRange.lowerBound) / Double(columns)
                let x0 = Int((WarpField.center(column: c, of: columns) - cellW * 0.6) * Double(gray.width))
                let x1 = Int((WarpField.center(column: c, of: columns) + cellW * 0.6) * Double(gray.width))
                if let m = windowAngle(gray, x: max(0, x0)..<min(gray.width, x1), y: max(0, y0)..<min(gray.height, y1), threshold: threshold),
                   m.peakRatio >= minimumPeakRatio {
                    values[r * columns + c] = Float(m.degrees)
                    known[r * columns + c] = true
                }
            }
        }
        let reliable = Double(known.filter { $0 }.count) / Double(known.count)
        guard reliable >= 0.5 else { return nil }
        // Lücken aus den Nachbarn füllen, dann einmal glätten: Einzelne Messungen schwanken um ein paar Zehntelgrad.
        HandRemover.harmonicFill(&values, known: known, width: columns, height: rows, channels: 1)
        values = smoothed(values)
        guard let field = WarpField(columns: columns, rows: rows, angles: values) else { return nil }
        return DewarpEstimate(field: field, reliableShare: reliable)
    }

    /// Gewichtetes 3×3-Mittel (Mitte doppelt), am Rand mit den vorhandenen Nachbarn.
    static func smoothed(_ values: [Float]) -> [Float] {
        var result = values
        for r in 0..<rows { for c in 0..<columns {
            var sum: Float = 0, weight: Float = 0
            for dr in -1...1 { for dc in -1...1 {
                let rr = r + dr, cc = c + dc
                guard rr >= 0, rr < rows, cc >= 0, cc < columns else { continue }
                let w: Float = (dr == 0 && dc == 0) ? 2 : 1
                sum += values[rr * columns + cc] * w; weight += w
            } }
            result[r * columns + c] = sum / weight
        } }
        return result
    }

    /// Zeilenwinkel in einem Fenster: Projektionsprofil über Winkel, grob in Zehntelgrad, dann fein.
    static func windowAngle(_ gray: GrayBitmap, x xs: Range<Int>, y ys: Range<Int>, threshold: UInt8) -> (degrees: Double, peakRatio: Double)? {
        guard xs.count >= 16, ys.count >= 16 else { return nil }
        var points: [(Float, Float)] = []
        var dark = 0
        for y in ys { for x in xs where gray.pixels[y * gray.width + x] < threshold { dark += 1 } }
        guard dark >= minimumPoints else { return nil }
        let sampling = max(1, dark / maxPoints)
        var counter = 0
        for y in ys { for x in xs where gray.pixels[y * gray.width + x] < threshold {
            counter += 1
            if counter % sampling == 0 { points.append((Float(x), Float(y))) }
        } }
        let size = Int((Double(gray.width * gray.width + gray.height * gray.height)).squareRoot()) + 2
        var histogram = [Float](repeating: 0, count: size * 2)
        func score(_ degrees: Double) -> Double {
            let radians = degrees * .pi / 180
            let c = Float(cos(radians)), s = Float(sin(radians))
            for i in histogram.indices { histogram[i] = 0 }
            let offset = Float(size)
            for (x, y) in points { histogram[Int(x * s + y * c + offset)] += 1 }
            var sum: Float = 0, sumSquares: Float = 0
            for v in histogram { sum += v; sumSquares += v * v }
            let n = Float(histogram.count)
            return Double(sumSquares / n - (sum / n) * (sum / n))
        }
        let coarse = Swift.stride(from: searchRange.lowerBound, through: searchRange.upperBound, by: 0.1).map { ($0, score($0)) }
        guard let best = coarse.max(by: { $0.1 < $1.1 }) else { return nil }
        let fine = Swift.stride(from: best.0 - 0.1, through: best.0 + 0.1, by: 0.025).map { ($0, score($0)) }
        guard let refined = fine.max(by: { $0.1 < $1.1 }) else { return nil }
        let median = coarse.map(\.1).sorted()[coarse.count / 2]
        guard median > 0 else { return nil }
        return (refined.0, refined.1 / median)
    }
}

/// Verschiebt jede Spalte einer Seite senkrecht so, dass die Zeilen überall auf demselben Winkel laufen.
public enum DewarpRenderer {
    /// - Parameters:
    ///   - field: Zeilenwinkel auf dem Raster.
    ///   - reference: Winkel in Grad, auf den die Zeilen gebracht werden (der der Drehung). Die Drehung danach stellt sie waagerecht.
    ///
    /// Eine Zeile mit dem Winkel θ steigt nach rechts um tan θ je Bildpunkt. Gesucht ist die Verschiebung S(x, y) = ∫ (tan θ − tan θ_ref) dx,
    /// vom Seitenmittelpunkt aus: Dort bleibt alles stehen, nach außen wächst sie. Das Ergebnis an (x, y) ist das Original an (x, y − S).
    /// tan wird durch den Winkel im Bogenmaß ersetzt (Fehler unter 0,5 % bis 6°).
    public static func apply(to image: CGImage, field: WarpField, reference: Double) -> CGImage? {
        let w = image.width, h = image.height
        guard w >= 8, h >= 8 else { return image }
        // Der Farbraum des Bildes, wenn es ein RGB-Raum ist; Graubilder und andere Räume werden in sRGB gerechnet.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        let bytesPerRow = w * 4
        var input = [UInt8](repeating: 0, count: h * bytesPerRow)
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        let drawn = input.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: space, bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        let columns = field.columns, rows = field.rows
        let refRadians = reference * .pi / 180
        let center = Double(w) / 2
        // I_c(x) = Integral der Spaltengewichte von der Mitte bis x (in Bildpunkten), je Spalte des Rasters.
        var integral = [[Double]](repeating: [Double](repeating: 0, count: w), count: columns)
        var weightsAtX = [(lower: Int, upper: Int, share: Double)](repeating: (0, 0, 0), count: w)
        for x in 0..<w { weightsAtX[x] = WarpField.weights(at: (Double(x) + 0.5) / Double(w), count: columns) { WarpField.center(column: $0, of: columns) } }
        func weight(_ c: Int, _ x: Int) -> Double {
            let k = weightsAtX[x]
            return (c == k.lower ? 1 - k.share : 0) + (c == k.upper ? k.share : 0)
        }
        // Kumuliert nach rechts und nach links von der Mitte (Trapezregel).
        let mid = min(w - 1, max(0, Int(center)))
        for c in 0..<columns {
            var acc = 0.0
            if mid + 1 < w { for x in (mid + 1)..<w { acc += (weight(c, x - 1) + weight(c, x)) / 2; integral[c][x] = acc } }
            acc = 0
            if mid > 0 { for x in stride(from: mid - 1, through: 0, by: -1) { acc -= (weight(c, x + 1) + weight(c, x)) / 2; integral[c][x] = acc } }
        }

        var output = input
        input.withUnsafeBufferPointer { src in output.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                // B_c(y): Winkel der Rasterspalte c in dieser Höhe, in Bogenmaß.
                let ry = WarpField.weights(at: (Double(y) + 0.5) / Double(h), count: rows) { WarpField.center(row: $0, of: rows) }
                var b = [Double](repeating: 0, count: columns)
                for c in 0..<columns {
                    let lo = Double(field.angles[ry.lower * columns + c]), hi = Double(field.angles[ry.upper * columns + c])
                    b[c] = (lo * (1 - ry.share) + hi * ry.share) * .pi / 180
                }
                for x in 0..<w {
                    var shift = -refRadians * (Double(x) - center)
                    for c in 0..<columns { shift += b[c] * integral[c][x] }
                    let source = Double(y) - shift
                    let clamped = min(Double(h - 1), max(0, source))
                    let y0 = Int(clamped), y1 = min(h - 1, y0 + 1), t = Float(clamped - Double(y0))
                    let i0 = y0 * bytesPerRow + x * 4, i1 = y1 * bytesPerRow + x * 4, o = y * bytesPerRow + x * 4
                    for ch in 0..<3 { dst[o + ch] = UInt8(max(0, min(255, (Float(src[i0 + ch]) * (1 - t) + Float(src[i1 + ch]) * t).rounded()))) }
                    dst[o + 3] = 255
                }
            }
        } }
        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
