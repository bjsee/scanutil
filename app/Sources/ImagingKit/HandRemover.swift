import CoreGraphics
import CoreImage
import Foundation

/// Entfernt Hände und Daumen aus einem Bild: Die Fläche wird mit dem Papierton aus ihrer Umgebung gefüllt.
///
/// Der Füllton entsteht auf einem kleinen Raster als harmonische Füllung: Jede Zelle der Hand ist der Mittelwert ihrer
/// Nachbarn, die Ränder sind das sichtbare Papier. Das ergibt eine glatte Fläche in der Farbe und Helligkeit des Papiers
/// an dieser Stelle, auch bei einem Helligkeitsverlauf. Text unter einem Daumen lässt sich nicht wiederherstellen, aber
/// Daumen liegen auf dem Seitenrand.
public enum HandRemover {
    private static let context = CIContext()
    /// Längste Kante des Füllrasters in Zellen.
    static let fieldSize = 400

    /// Das Bild ohne die Flächen der Maske. Gibt das Bild unverändert zurück, wenn die Maske leer ist.
    public static func apply(to image: CGImage, mask: HandMask) -> CGImage? {
        guard !mask.isEmpty else { return image }
        guard let field = fillField(for: image, mask: mask) else { return nil }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let original = CIImage(cgImage: image)

        // Füllung und Maske auf die Größe des Bildes bringen, die Maske etwas weich zeichnen: kein harter Rand.
        let fill = CIImage(cgImage: field)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(field.width), y: extent.height / CGFloat(field.height)))
            .samplingLinear().cropped(to: extent)
        guard let maskImage = maskCGImage(mask) else { return nil }
        let feather = max(1.5, Double(extent.width) / 600)
        let softMask = CIImage(cgImage: maskImage)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(mask.width), y: extent.height / CGFloat(mask.height)))
            .samplingLinear().clampedToExtent()
            .applyingGaussianBlur(sigma: feather).cropped(to: extent)

        let blended = fill.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: original, kCIInputMaskImageKey: softMask,
        ])
        return context.createCGImage(blended, from: extent)
    }

    // MARK: Füllung

    /// Das gefüllte Raster in RGB: überall der Papierton, an den Stellen der Hand aus der Umgebung gerechnet.
    static func fillField(for image: CGImage, mask: HandMask) -> CGImage? {
        guard let rgb = RGBBitmap(image, width: min(fieldSize, image.width)) else { return nil }
        let w = rgb.width, h = rgb.height
        // Die Maske auf das Raster bringen (nächster Nachbar) und etwas verbreitern, damit der Rand der Finger nicht Randwert wird.
        var isHand = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let my = min(mask.height - 1, y * mask.height / h)
            for x in 0..<w { isHand[y * w + x] = mask.cells[my * mask.width + min(mask.width - 1, x * mask.width / w)] > 127 }
        }
        // Etwas Abstand: Schatten neben dem Daumen oder Marker färbt sonst den Rand der Füllung grau.
        isHand = HandDetector.dilate(isHand, width: w, height: h, radius: 5)

        var values = [Float](repeating: 0, count: w * h * 3)
        var paper = [Bool](repeating: false, count: w * h)
        var dark = [Bool](repeating: false, count: w * h)
        var darkSum: [Float] = [0, 0, 0], darkCount: Float = 0
        for i in 0..<(w * h) {
            let r = Float(rgb.pixels[i * 4]) / 255, g = Float(rgb.pixels[i * 4 + 1]) / 255, b = Float(rgb.pixels[i * 4 + 2]) / 255
            values[i * 3] = r; values[i * 3 + 1] = g; values[i * 3 + 2] = b
            guard !isHand[i] else { continue }
            if max(r, g, b) >= 0.25 { paper[i] = true } else { dark[i] = true; darkSum[0] += r; darkSum[1] += g; darkSum[2] += b; darkCount += 1 }
        }
        guard paper.contains(true) else { return nil }
        // Als Vorlage dienen nur die hellen, kaum gesättigten Papierpixel. Textzeilen, Strichzeichnungen und ein farbiger Einband
        // würden den Füllton sonst grau oder bunt färben. Bleibt davon zu wenig, gilt alles Sichtbare.
        var paperLike = paper
        var brightness: [Float] = []
        brightness.reserveCapacity(w * h)
        for i in 0..<(w * h) where paper[i] { brightness.append(max(values[i * 3], values[i * 3 + 1], values[i * 3 + 2])) }
        brightness.sort()
        let median = brightness[brightness.count / 2]
        var count = 0
        for i in 0..<(w * h) where paper[i] {
            let r = values[i * 3], g = values[i * 3 + 1], b = values[i * 3 + 2]
            let top = max(r, g, b), saturation = top > 0 ? (top - min(r, g, b)) / top : 0
            paperLike[i] = top >= 0.6 * median && saturation <= 0.30
            if paperLike[i] { count += 1 }
        }
        if count < brightness.count / 5 { paperLike = paper }
        // Das Papier füllt die Hand harmonisch aus. Der dunkle Hintergrund zählt dabei nicht, er soll nicht ins Papier einfärben.
        // Gerechnet wird nur in einem Ausschnitt um jede Handfläche, mit Rand: Unbekannt ist im ganzen Bild auch das Tuch, die Hälfte
        // des Rasters, und dort wäre jede Rechnung umsonst.
        for component in HandDetector.components(isHand, width: w, height: h) {
            var minX = w, maxX = 0, minY = h, maxY = 0
            for cell in component.cells {
                let x = cell % w, y = cell / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
            let margin = max(16, Int(0.12 * Double(max(w, h))))
            let x0 = max(0, minX - margin), x1 = min(w - 1, maxX + margin), y0 = max(0, minY - margin), y1 = min(h - 1, maxY + margin)
            let sw = x1 - x0 + 1, sh = y1 - y0 + 1
            var window = [Float](repeating: 0, count: sw * sh * 3), windowKnown = [Bool](repeating: false, count: sw * sh)
            for y in y0...y1 {
                for x in x0...x1 {
                    let source = y * w + x, target = (y - y0) * sw + (x - x0)
                    for c in 0..<3 { window[target * 3 + c] = values[source * 3 + c] }
                    windowKnown[target] = paperLike[source]
                }
            }
            guard windowKnown.contains(true) else { continue }
            harmonicFill(&window, known: windowKnown, width: sw, height: sh, channels: 3)
            for cell in component.cells {
                let x = cell % w, y = cell / w, target = (y - y0) * sw + (x - x0)
                for c in 0..<3 { values[cell * 3 + c] = window[target * 3 + c] }
            }
        }
        // Ragt ein Finger über den Rand der Seite auf das Tuch hinaus, soll dort das Tuch bleiben und kein Papier erscheinen:
        // Jede Stelle der Hand übernimmt, was ihr näher liegt, sichtbares Papier oder sichtbarer Hintergrund.
        let background: [Float] = darkCount > 0 ? darkSum.map { $0 / darkCount } : [0.02, 0.02, 0.02]
        if dark.contains(true) {
            let toPaper = distances(from: paper, width: w, height: h), toDark = distances(from: dark, width: w, height: h)
            for i in 0..<(w * h) where isHand[i] && toDark[i] < toPaper[i] {
                for c in 0..<3 { values[i * 3 + c] = background[c] }
            }
        }

        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 { bytes[i * 4 + c] = UInt8(max(0, min(255, (values[i * 3 + c] * 255).rounded()))) }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Füllt die unbekannten Zellen harmonisch, grob nach fein: Auf dem kleinsten Raster reichen wenige Schritte bis in die
    /// Mitte einer großen Lücke, die gröbere Lösung ist dann der Startwert der nächsten Stufe.
    static func harmonicFill(_ values: inout [Float], known: [Bool], width w: Int, height h: Int, channels: Int) {
        guard known.contains(false) else { return }
        if w > 8, h > 8 {
            // Eine Stufe gröber: Mittelwert der bekannten Zellen eines 2×2-Blocks, unbekannt, wenn keine bekannt ist.
            let cw = (w + 1) / 2, ch = (h + 1) / 2
            var coarse = [Float](repeating: 0, count: cw * ch * channels)
            var coarseKnown = [Bool](repeating: false, count: cw * ch)
            for cy in 0..<ch {
                for cx in 0..<cw {
                    var count: Float = 0
                    var sum = SIMD4<Float>()   // bis zu vier Kanäle, ohne Array je Zelle
                    for dy in 0..<2 { for dx in 0..<2 {
                        let x = cx * 2 + dx, y = cy * 2 + dy
                        guard x < w, y < h, known[y * w + x] else { continue }
                        count += 1
                        for c in 0..<channels { sum[c] += values[(y * w + x) * channels + c] }
                    } }
                    if count > 0 {
                        coarseKnown[cy * cw + cx] = true
                        for c in 0..<channels { coarse[(cy * cw + cx) * channels + c] = sum[c] / count }
                    }
                }
            }
            if coarseKnown.contains(true) {
                harmonicFill(&coarse, known: coarseKnown, width: cw, height: ch, channels: channels)
                // Die gröbere Lösung als Startwert der unbekannten Zellen.
                for y in 0..<h { for x in 0..<w where !known[y * w + x] {
                    for c in 0..<channels { values[(y * w + x) * channels + c] = coarse[((y / 2) * cw + (x / 2)) * channels + c] }
                } }
            } else {
                let mean = mean(of: values, known: known, channels: channels)
                for i in 0..<(w * h) where !known[i] { for c in 0..<channels { values[i * channels + c] = mean[c] } }
            }
        } else {
            let mean = mean(of: values, known: known, channels: channels)
            for i in 0..<(w * h) where !known[i] { for c in 0..<channels { values[i * channels + c] = mean[c] } }
        }
        relax(&values, known: known, width: w, height: h, channels: channels, iterations: w > 100 ? 60 : 120)
    }

    /// Abstand jeder Zelle zur nächsten Quellzelle in Schritten (Breitensuche, Vierer-Nachbarschaft).
    static func distances(from sources: [Bool], width w: Int, height h: Int) -> [Int32] {
        var distance = [Int32](repeating: Int32.max, count: w * h)
        var queue: [Int] = []
        queue.reserveCapacity(w * h)
        for i in 0..<(w * h) where sources[i] { distance[i] = 0; queue.append(i) }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w, next = distance[i] + 1
            if x > 0, distance[i - 1] == Int32.max { distance[i - 1] = next; queue.append(i - 1) }
            if x < w - 1, distance[i + 1] == Int32.max { distance[i + 1] = next; queue.append(i + 1) }
            if y > 0, distance[i - w] == Int32.max { distance[i - w] = next; queue.append(i - w) }
            if y < h - 1, distance[i + w] == Int32.max { distance[i + w] = next; queue.append(i + w) }
        }
        return distance
    }

    private static func mean(of values: [Float], known: [Bool], channels: Int) -> [Float] {
        var sum = [Float](repeating: 0, count: channels), count: Float = 0
        for i in 0..<known.count where known[i] { count += 1; for c in 0..<channels { sum[c] += values[i * channels + c] } }
        return sum.map { count > 0 ? $0 / count : 0.9 }
    }

    /// Gauß-Seidel-Schritte: jede unbekannte Zelle wird der Mittelwert ihrer vier Nachbarn. Es werden nur die unbekannten
    /// Zellen durchlaufen (eine Hand ist ein paar Prozent des Rasters), ihre Nachbarn einmal vorab bestimmt.
    private static func relax(_ values: inout [Float], known: [Bool], width w: Int, height h: Int, channels: Int, iterations: Int) {
        var cells: [Int] = [], left: [Int] = [], right: [Int] = [], up: [Int] = [], down: [Int] = []
        for y in 0..<h {
            for x in 0..<w where !known[y * w + x] {
                cells.append(y * w + x)
                left.append(y * w + (x > 0 ? x - 1 : x)); right.append(y * w + (x < w - 1 ? x + 1 : x))
                up.append((y > 0 ? y - 1 : y) * w + x); down.append((y < h - 1 ? y + 1 : y) * w + x)
            }
        }
        guard !cells.isEmpty else { return }
        values.withUnsafeMutableBufferPointer { v in
            cells.withUnsafeBufferPointer { cell in left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in
            up.withUnsafeBufferPointer { u in down.withUnsafeBufferPointer { d in
                for _ in 0..<iterations {
                    for k in 0..<cell.count {
                        let i = cell[k] * channels
                        let a = l[k] * channels, b = r[k] * channels, c = u[k] * channels, e = d[k] * channels
                        for ch in 0..<channels { v[i + ch] = (v[a + ch] + v[b + ch] + v[c + ch] + v[e + ch]) * 0.25 }
                    }
                }
            } } } } }
        }
    }

    private static func maskCGImage(_ mask: HandMask) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(mask.cells) as CFData) else { return nil }
        return CGImage(width: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: mask.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
