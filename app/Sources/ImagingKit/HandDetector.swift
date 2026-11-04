import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Maske der Hände und Daumen in einem Bild, in niedriger Auflösung. Eine Zelle ist 255 (Hand) oder 0.
public struct HandMask: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let cells: [UInt8]

    public init?(width: Int, height: Int, cells: [UInt8]) {
        guard width > 0, height > 0, cells.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.cells = cells
    }

    /// Anteil der Zellen, die zur Hand gehören, von 0 bis 1.
    public var coverage: Double { Double(cells.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }) / Double(cells.count) }
    public var isEmpty: Bool { !cells.contains { $0 > 127 } }

    /// Als PNG, um die Maske in den Korrekturen mitzuspeichern: ein paar Kilobyte statt eines Bildes.
    public func pngData() -> Data? {
        let provider = CGDataProvider(data: Data(cells) as CFData)
        guard let provider,
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    public init?(pngData: Data) {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var cells = [UInt8](repeating: 0, count: w * h)
        let drawn = cells.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, cells: cells)
    }
}

/// Ergebnis der Handerkennung.
public struct HandDetection: Equatable, Sendable {
    public let mask: HandMask
    /// Anzahl getrennter Hand- oder Fingerflächen in der Maske, die Marker eingeschlossen.
    public let regions: Int
    /// Davon Daumen-Marker (die gelben Klemmen).
    public let markers: Int
    /// Sicherheit von 0 bis 1.
    public let confidence: Double
}

/// Findet Hände und Daumen, die das Buch halten, an ihrer Hautfarbe, und die gelben Daumen-Marker des Scanners an ihrem Gelb.
///
/// Bei der Haut zählen nur Flächen, die zum Rand der Seite gehören: vom Tuch hereinragende Finger und Daumen auf dem Seitenrand.
/// Hautfarbene Stellen mitten auf der Seite (eine Zeichnung, ein Foto) sind keine Hände und bleiben unberührt.
public enum HandDetector {
    /// Breite des Arbeitsbildes in Pixeln.
    static let workingWidth = 800
    /// Kleinste Fläche, die als Hand zählt, als Anteil des Bildes. Kleiner sind Staub und Rauschen.
    static let minimumArea = 0.0015
    /// Marker sind klein, aber unverwechselbar gelb: Fläche eines einzelnen Markers samt Punktfeld, als Anteil des Bildes.
    static let markerArea = 0.0005...0.05
    /// So weit reicht der Randstreifen im Inneren der Seite, als Anteil der kürzeren Seitenkante.
    static let edgeZone = 0.10

    /// - Parameter page: Rand der Seite oder Doppelseite in normierten Bildkoordinaten. Ohne Angabe gilt der Bildrand.
    public static func detect(in image: CGImage, page: Quad? = nil) -> HandDetection? {
        guard let rgb = RGBBitmap(image, width: workingWidth) else { return nil }
        let w = rgb.width, h = rgb.height
        var skin = [Bool](repeating: false, count: w * h)
        rgb.pixels.withUnsafeBufferPointer { p in
            for i in 0..<(w * h) { skin[i] = isSkin(r: p[i * 4], g: p[i * 4 + 1], b: p[i * 4 + 2]) }
        }
        skin = close(skin, width: w, height: h, radius: max(2, w / 200))

        let edge = edgeZoneCells(page: page, width: w, height: h)
        let labeled = components(skin, width: w, height: h)
        let minimum = max(20, Int(minimumArea * Double(w * h)))
        var mask = [UInt8](repeating: 0, count: w * h)
        var kept = 0
        for component in labeled where component.cells.count >= minimum {
            // Eine Hand hält das Buch von außen: sie berührt den Randstreifen. Eine Zeichnung mitten auf der Seite nicht.
            guard component.cells.contains(where: { edge[$0] }) else { continue }
            for cell in component.cells { mask[cell] = 255 }
            kept += 1
        }
        // Die Daumen-Marker: gelb, mit schwarz-weißem Punktfeld, das Schließen und Löcherfüllen einbezieht.
        var markerCount = 0
        var markerCells = [Bool](repeating: false, count: w * h)
        var yellow = [Bool](repeating: false, count: w * h)
        rgb.pixels.withUnsafeBufferPointer { p in
            for i in 0..<(w * h) { yellow[i] = isMarkerYellow(r: p[i * 4], g: p[i * 4 + 1], b: p[i * 4 + 2]) }
        }
        // Großer Schließradius: das schwarz-weiße Punktfeld sitzt am Rand des Markers und muss mit hinein.
        yellow = fillHoles(close(yellow, width: w, height: h, radius: max(6, w / 28)), width: w, height: h)
        let markerMin = Int(markerArea.lowerBound * Double(w * h)), markerMax = Int(markerArea.upperBound * Double(w * h))
        for component in components(yellow, width: w, height: h) where (markerMin...markerMax).contains(component.cells.count) {
            // Ein Marker liegt am Rand der Seite. Ist der Seitenrand noch unbekannt, genügt die Farbe: so lässt sich das Bild
            // bereinigen, bevor Vision den Rand sucht.
            guard page == nil || component.cells.contains(where: { edge[$0] }) else { continue }
            for cell in component.cells { mask[cell] = 255; markerCells[cell] = true }
            markerCount += 1
        }
        kept += markerCount
        guard kept > 0 else { return nil }
        // Etwas verbreitern: Schatten und die weichen Ränder der Finger gehören dazu.
        // Danach Löcher füllen: Ein überstrahlter Glanzpunkt mitten im Marker ist weder gelb noch hautfarben, wäre sonst aber
        // eine Lücke in der Maske. Das Verbreitern schließt vorher feine Spalten, durch die das Füllen sonst entwiche.
        var grown = fillHoles(dilate(mask.map { $0 > 127 }, width: w, height: h, radius: max(3, w / 130)), width: w, height: h)
        // Ein Marker wirft einen Schatten aufs Papier, der als dunkler Saum neben der Füllung stehen bliebe: Um ihn herum
        // wird deutlich weiter verbreitert als um Finger.
        if markerCount > 0 {
            let shadow = dilate(markerCells, width: w, height: h, radius: max(8, w / 40))
            for i in 0..<(w * h) where shadow[i] { grown[i] = true }
        }
        let cells = grown.map { $0 ? UInt8(255) : 0 }
        guard let result = HandMask(width: w, height: h, cells: cells) else { return nil }
        // Sehr große Flächen sind eher ein hautfarbener Einband als Hände.
        let coverage = result.coverage
        guard coverage < 0.30 else { return nil }
        return HandDetection(mask: result, regions: kept, markers: markerCount, confidence: 1)
    }

    /// Vereinigt zwei Erkennungen desselben Bildes zu einer. Eine fehlende zählt nicht.
    public static func union(_ a: HandDetection?, _ b: HandDetection?) -> HandDetection? {
        guard let a else { return b }
        guard let b else { return a }
        guard a.mask.width == b.mask.width, a.mask.height == b.mask.height,
              let mask = HandMask(width: a.mask.width, height: a.mask.height,
                                  cells: zip(a.mask.cells, b.mask.cells).map { max($0, $1) }) else { return a }
        return HandDetection(mask: mask, regions: max(a.regions, b.regions), markers: max(a.markers, b.markers),
                             confidence: min(a.confidence, b.confidence))
    }

    /// Hautfarbe: rötlich bis orange, mäßig gesättigt, nicht zu dunkel. Das Papier ist cremeweiß (Farbton um 45°, kaum gesättigt),
    /// der Hintergrund schwarz, beides fällt heraus.
    static func isSkin(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxC = max(rf, gf, bf), minC = min(rf, gf, bf)
        let delta = maxC - minC
        // Mindesthelligkeit 0,40: Der gelbliche Widerschein und Schatten der Marker auf dem dunklen Tuch hat Hautfarbton,
        // liegt aber knapp über 0,3 und darf keine „Hand“ ergeben.
        guard maxC >= 0.40, maxC <= 0.98, delta > 0 else { return false }
        let saturation = delta / maxC
        guard saturation >= 0.18, saturation <= 0.75 else { return false }
        guard rf >= gf, gf >= bf, rf - gf >= 0.03 else { return false }
        var hue = 60 * ((gf - bf) / delta)
        if hue < 0 { hue += 360 }
        return hue <= 40 || hue >= 345
    }

    /// Das Gelb der Daumen-Marker: gemessen an den Markern allein auf dem Tuch und auf dem Buch (Farbton 49–60°, Sättigung 0,5 bis 1,0,
    /// Helligkeit ab 0,64). Papier ist kaum gesättigt (unter 0,06), Haut liegt unter 40° Farbton: beides bleibt weit entfernt.
    static func isMarkerYellow(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxC = max(rf, gf, bf), minC = min(rf, gf, bf), delta = maxC - minC
        guard maxC >= 0.55, delta > 0 else { return false }
        let saturation = delta / maxC
        // Kräftiges Gelb, oder die überstrahlten Glanzstellen des Plastiks: fast weißgelb, aber mit Sättigung ab 0,18
        // (Papier liegt gemessen bei höchstens 0,06) und sehr hell.
        guard saturation >= 0.45 || (saturation >= 0.18 && maxC >= 0.85) else { return false }
        guard maxC == rf || maxC == gf, bf <= gf, bf <= rf else { return false }
        var hue = 60 * ((gf - bf) / delta)
        if maxC == gf, maxC != rf { hue = 60 * ((bf - rf) / delta + 2) }
        if hue < 0 { hue += 360 }
        return hue >= 42 && hue <= 70
    }

    /// Füllt Löcher: Zellen, die vom Rand des Bildes aus nicht erreichbar sind, ohne eine gesetzte Zelle zu kreuzen.
    static func fillHoles(_ mask: [Bool], width w: Int, height h: Int) -> [Bool] {
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w { for y in [0, h - 1] { let i = y * w + x; if !mask[i], !outside[i] { outside[i] = true; stack.append(i) } } }
        for y in 0..<h { for x in [0, w - 1] { let i = y * w + x; if !mask[i], !outside[i] { outside[i] = true; stack.append(i) } } }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0, !mask[i - 1], !outside[i - 1] { outside[i - 1] = true; stack.append(i - 1) }
            if x < w - 1, !mask[i + 1], !outside[i + 1] { outside[i + 1] = true; stack.append(i + 1) }
            if y > 0, !mask[i - w], !outside[i - w] { outside[i - w] = true; stack.append(i - w) }
            if y < h - 1, !mask[i + w], !outside[i + w] { outside[i + w] = true; stack.append(i + w) }
        }
        return (0..<(w * h)).map { mask[$0] || !outside[$0] }
    }

    /// Zellen, die im Randstreifen der Seite oder außerhalb liegen.
    private static func edgeZoneCells(page: Quad?, width w: Int, height h: Int) -> [Bool] {
        var zone = [Bool](repeating: false, count: w * h)
        guard let quad = page else {
            // Ohne Seitenrand: der Bildrand.
            let band = max(2, w / 60)
            for y in 0..<h { for x in 0..<w where x < band || y < band || x >= w - band || y >= h - band { zone[y * w + x] = true } }
            return zone
        }
        let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
            .map { CGPoint(x: $0.x * Double(w), y: $0.y * Double(h)) }
        let shortSide = min(distance(corners[0], corners[1]), distance(corners[0], corners[3]))
        let band = edgeZone * Double(shortSide)
        for y in 0..<h {
            for x in 0..<w {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                // Außerhalb oder dicht an einer Kante des Vierecks.
                var nearest = Double.infinity, inside = true
                for i in 0..<4 {
                    let a = corners[i], b = corners[(i + 1) % 4]
                    let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                    if cross < 0 { inside = false }
                    nearest = min(nearest, segmentDistance(p, a, b))
                }
                zone[y * w + x] = !inside || nearest <= band
            }
        }
        return zone
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    // MARK: Morphologie und Flächen

    struct Component { var cells: [Int] }

    static func components(_ mask: [Bool], width w: Int, height h: Int) -> [Component] {
        var visited = [Bool](repeating: false, count: w * h)
        var result: [Component] = []
        for start in 0..<(w * h) where mask[start] && !visited[start] {
            var stack = [start], cells: [Int] = []
            visited[start] = true
            while let i = stack.popLast() {
                cells.append(i)
                let x = i % w, y = i / w
                // Die vier Nachbarn einzeln prüfen: ein Array je Zelle würde Hunderttausende Allokationen kosten.
                if x > 0, mask[i - 1], !visited[i - 1] { visited[i - 1] = true; stack.append(i - 1) }
                if x < w - 1, mask[i + 1], !visited[i + 1] { visited[i + 1] = true; stack.append(i + 1) }
                if y > 0, mask[i - w], !visited[i - w] { visited[i - w] = true; stack.append(i - w) }
                if y < h - 1, mask[i + w], !visited[i + w] { visited[i + w] = true; stack.append(i + w) }
            }
            result.append(Component(cells: cells))
        }
        return result
    }

    /// Schließt kleine Lücken zwischen Hautflächen (Schatten zwischen den Fingern, Falten).
    static func close(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        erode(dilate(mask, width: width, height: height, radius: radius), width: width, height: height, radius: radius)
    }

    static func dilate(_ mask: [Bool], width w: Int, height h: Int, radius r: Int) -> [Bool] {
        separable(mask, width: w, height: h, radius: r, any: true)
    }

    static func erode(_ mask: [Bool], width w: Int, height h: Int, radius r: Int) -> [Bool] {
        separable(mask, width: w, height: h, radius: r, any: false)
    }

    /// Quadratisches Strukturelement als zwei Durchläufe (waagerecht, senkrecht) mit laufender Summe.
    private static func separable(_ mask: [Bool], width w: Int, height h: Int, radius r: Int, any: Bool) -> [Bool] {
        func pass(_ input: [Bool], count: Int, lines: Int, stride: Int, step: Int) -> [Bool] {
            var output = input
            for line in 0..<lines {
                let base = line * stride
                var window = 0
                // Anfangsfenster [0, r].
                for k in 0...min(r, count - 1) { window += input[base + k * step] ? 1 : 0 }
                for k in 0..<count {
                    let size = min(count - 1, k + r) - max(0, k - r) + 1
                    output[base + k * step] = any ? window > 0 : window == size
                    let leaving = k - r, entering = k + r + 1
                    if leaving >= 0 { window -= input[base + leaving * step] ? 1 : 0 }
                    if entering < count { window += input[base + entering * step] ? 1 : 0 }
                }
            }
            return output
        }
        let horizontal = pass(mask, count: w, lines: h, stride: w, step: 1)
        return pass(horizontal, count: h, lines: w, stride: 1, step: w)
    }
}

/// RGBA-Bild im Speicher, auf eine Breite verkleinert.
struct RGBBitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage, width target: Int) {
        let scale = min(1, Double(target) / Double(image.width))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        pixels = data
    }
}
