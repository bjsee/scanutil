import CoreGraphics
import Foundation

/// Findet das ganze Papier eines alten Dokuments auf dunklem Untergrund: den Rahmen um die helle Fläche samt einem schmalen schwarzen
/// Rand. Die gewöhnliche Dokumenterkennung sucht ein Viereck und schneidet bei eingerissenen, ausgefransten oder abgerundeten Blättern
/// Papier ab; hier zählt nur, wo Papier liegt.
public enum PaperBounds {
    /// Längste Kante des Bildes, auf dem gemessen wird.
    static let workingSize = 1000
    /// Der schwarze Rand um das Papier, als Anteil von Breite und Höhe des Papiers.
    public static let defaultMargin = 0.03
    /// Eine Papierfläche, die kleiner ist als dieser Anteil des Bildes, gilt als nicht gefunden (Staub, Spiegelung).
    static let minimumArea = 0.04

    /// - Parameters:
    ///   - margin: Schwarzer Rand um das Papier als Anteil von dessen Breite und Höhe.
    ///   - hands: Zellen der Hand (Maske der Handerkennung): Sie zählen nicht zum Papier, sonst zöge ein Daumen den Rahmen auf.
    /// - Returns: Ein achsenparalleler Rahmen in normierten Koordinaten, oder `nil`, wenn kein Papier zu finden ist.
    public static func detect(in image: CGImage, margin: Double = defaultMargin, hands: HandMask? = nil) -> Quad? {
        guard let gray = GrayBitmap(image, maxDimension: workingSize), gray.width >= 16, gray.height >= 16 else { return nil }
        let w = gray.width, h = gray.height
        let threshold = min(110, max(25, Int(SkewEstimator.otsuThreshold(gray.pixels))))

        var paper = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where Int(gray.pixels[y * w + x]) >= threshold {
                if let hands {
                    let hx = min(hands.width - 1, x * hands.width / w), hy = min(hands.height - 1, y * hands.height / h)
                    if hands.cells[hy * hands.width + hx] > 127 { continue }
                }
                paper[y * w + x] = true
            }
        }
        // Einzelne helle Punkte (Staub, Körnung) und dünne Brücken fallen durch ein Abtragen weg; der Rahmen bekommt den Rand ohnehin.
        paper = eroded(paper, width: w, height: h, radius: 2)

        // Die größte zusammenhängende Fläche ist das Papier.
        var label = [Int32](repeating: 0, count: w * h)
        var best: (area: Int, minX: Int, maxX: Int, minY: Int, maxY: Int)?
        var next: Int32 = 0
        var stack: [Int] = []
        for start in 0..<(w * h) where paper[start] && label[start] == 0 {
            next += 1
            stack.append(start); label[start] = next
            var area = 0, minX = w, maxX = 0, minY = h, maxY = 0
            while let cell = stack.popLast() {
                let x = cell % w, y = cell / w
                area += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, paper[cell - 1], label[cell - 1] == 0 { label[cell - 1] = next; stack.append(cell - 1) }
                if x < w - 1, paper[cell + 1], label[cell + 1] == 0 { label[cell + 1] = next; stack.append(cell + 1) }
                if y > 0, paper[cell - w], label[cell - w] == 0 { label[cell - w] = next; stack.append(cell - w) }
                if y < h - 1, paper[cell + w], label[cell + w] == 0 { label[cell + w] = next; stack.append(cell + w) }
            }
            if best == nil || area > best!.area { best = (area, minX, maxX, minY, maxY) }
        }
        guard let found = best, Double(found.area) >= minimumArea * Double(w * h) else { return nil }

        // Das Abtragen hat den Rand um `radius` Punkte nach innen gerückt: wieder dazurechnen, dann der schwarze Rand.
        let radius = 2.0
        let left = Double(found.minX) - radius, right = Double(found.maxX) + 1 + radius
        let top = Double(found.minY) - radius, bottom = Double(found.maxY) + 1 + radius
        let marginX = max(6, (right - left) * margin), marginY = max(6, (bottom - top) * margin)
        let x0 = max(0, (left - marginX) / Double(w)), x1 = min(1, (right + marginX) / Double(w))
        let y0 = max(0, (top - marginY) / Double(h)), y1 = min(1, (bottom + marginY) / Double(h))
        return Quad(topLeft: .init(x: x0, y: y0), topRight: .init(x: x1, y: y0), bottomRight: .init(x: x1, y: y1), bottomLeft: .init(x: x0, y: y1))
    }

    /// Trägt die Fläche um `radius` Punkte ab (quadratisches Fenster, getrennt nach Zeilen und Spalten).
    static func eroded(_ mask: [Bool], width w: Int, height h: Int, radius: Int) -> [Bool] {
        func pass(_ input: [Bool], horizontal: Bool) -> [Bool] {
            var out = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w where input[y * w + x] {
                    var keep = true
                    for d in -radius...radius {
                        let xx = horizontal ? x + d : x, yy = horizontal ? y : y + d
                        // Außerhalb des Bildes zählt als Papier: Ein Blatt, das bis an den Bildrand reicht, soll nicht schrumpfen.
                        if xx < 0 || xx >= w || yy < 0 || yy >= h { continue }
                        if !input[yy * w + xx] { keep = false; break }
                    }
                    out[y * w + x] = keep
                }
            }
            return out
        }
        return pass(pass(mask, horizontal: true), horizontal: false)
    }
}
