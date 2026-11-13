import CoreGraphics
import Foundation

/// Zieht die Außenkanten des Seitenvierecks nach innen, solange dort kein Papier liegt: Einband (der grüne Streifen am Buchrand),
/// Tuch oder Schatten. Die Randerkennung folgt dem Buch als Ganzes, und zu dem gehört der Einbandrand; auf der Seite will man
/// ihn nicht sehen.
///
/// Je Kante wird entlang der Kante an vielen Stellen geprüft, wie weit man nach innen gehen muss, bis es Papier ist (hell,
/// kaum gefärbt). Stellen, die von einem Marker, einem Daumen oder Schrift verdeckt sind, zählen nicht gegen das Ergebnis:
/// Entscheidend ist, dass die meisten Stellen Papier sind.
enum EdgeRefiner {
    /// Breite des Messbildes in Pixeln.
    static let workingWidth = 1000
    /// So viel darf eine Kante höchstens wandern, als Anteil der Seitenbreite bzw. -höhe.
    static let maxShare = 0.05
    /// Anteil der Prüfstellen, die Papier sein müssen.
    static let paperShare = 0.75

    static func refine(_ quad: Quad, in image: CGImage) -> Quad {
        guard let rgb = RGBBitmap(image, width: workingWidth) else { return quad }
        let w = Double(rgb.width), h = Double(rgb.height)
        func pixel(_ n: NormalizedPoint) -> CGPoint { CGPoint(x: n.x * w, y: n.y * h) }
        var corners = [pixel(quad.topLeft), pixel(quad.topRight), pixel(quad.bottomRight), pixel(quad.bottomLeft)]
        let reference = paperReference(corners: corners, rgb: rgb)
        guard reference > 40 else { return quad }

        // Die vier Kanten nacheinander, jede auf dem Stand der vorigen: oben, rechts, unten, links (Ecken i → i+1).
        for edge in 0..<4 {
            let a = corners[edge], b = corners[(edge + 1) % 4]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 20 else { continue }
            // Einwärts: zum Mittelpunkt hin senkrecht zur Kante.
            let center = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
            var nx = -(b.y - a.y) / length, ny = (b.x - a.x) / length
            if (center.x - a.x) * nx + (center.y - a.y) * ny < 0 { nx = -nx; ny = -ny }
            let extent = (edge % 2 == 0) ? hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y)
                                          : hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y)
            let otherExtent = (edge % 2 == 0) ? hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y)
                                              : hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y)
            // Die Kante wandert in Richtung der anderen Seitenlänge: oben/unten um höchstens 5 % der Höhe, links/rechts der Breite.
            let limit = Int((maxShare * (edge % 2 == 0 ? otherExtent : extent)).rounded())
            guard limit >= 1 else { continue }
            let shift = shiftNeeded(from: a, to: b, normal: (nx, ny), limit: limit, rgb: rgb, reference: reference)
            guard shift > 0 else { continue }
            corners[edge] = CGPoint(x: a.x + nx * Double(shift), y: a.y + ny * Double(shift))
            corners[(edge + 1) % 4] = CGPoint(x: b.x + nx * Double(shift), y: b.y + ny * Double(shift))
        }
        func normalized(_ p: CGPoint) -> NormalizedPoint { NormalizedPoint(x: min(max(p.x / w, 0), 1), y: min(max(p.y / h, 0), 1)) }
        // Die verschobenen Kanten schneiden sich nicht mehr genau in den alten Ecken: Die Ecken sind die Schnittpunkte der Geraden.
        let lines = (0..<4).map { (corners[$0], corners[($0 + 1) % 4]) }
        func cross(_ l1: (CGPoint, CGPoint), _ l2: (CGPoint, CGPoint)) -> CGPoint? {
            let d1 = CGPoint(x: l1.1.x - l1.0.x, y: l1.1.y - l1.0.y), d2 = CGPoint(x: l2.1.x - l2.0.x, y: l2.1.y - l2.0.y)
            let denom = d1.x * d2.y - d1.y * d2.x
            guard abs(denom) > 1e-9 else { return nil }
            let t = ((l2.0.x - l1.0.x) * d2.y - (l2.0.y - l1.0.y) * d2.x) / denom
            return CGPoint(x: l1.0.x + d1.x * t, y: l1.0.y + d1.y * t)
        }
        guard let tl = cross(lines[3], lines[0]), let tr = cross(lines[0], lines[1]),
              let br = cross(lines[1], lines[2]), let bl = cross(lines[2], lines[3]) else { return quad }
        return Quad(topLeft: normalized(tl), topRight: normalized(tr), bottomRight: normalized(br), bottomLeft: normalized(bl))
    }

    /// Helligkeit des Papiers: Median der Helligkeit auf der Mitte des Vierecks.
    private static func paperReference(corners: [CGPoint], rgb: RGBBitmap) -> Double {
        var values: [Double] = []
        for iy in 0..<12 { for ix in 0..<12 {
            let u = 0.3 + 0.4 * Double(ix) / 11, v = 0.3 + 0.4 * Double(iy) / 11
            let top = CGPoint(x: corners[0].x + (corners[1].x - corners[0].x) * u, y: corners[0].y + (corners[1].y - corners[0].y) * u)
            let bottom = CGPoint(x: corners[3].x + (corners[2].x - corners[3].x) * u, y: corners[3].y + (corners[2].y - corners[3].y) * u)
            let p = CGPoint(x: top.x + (bottom.x - top.x) * v, y: top.y + (bottom.y - top.y) * v)
            if let (b, s) = sample(rgb, p), s < 0.3 { values.append(b) }
        } }
        guard values.count >= 20 else { return 0 }
        values.sort()
        return values[values.count * 7 / 10]
    }

    /// Wie weit die Kante nach innen muss, bis dort Papier liegt (in Pixeln des Messbildes), oder 0, wenn sie schon darauf liegt.
    private static func shiftNeeded(from a: CGPoint, to b: CGPoint, normal: (Double, Double), limit: Int, rgb: RGBBitmap, reference: Double) -> Int {
        let positions = stride(from: 0.15, through: 0.85, by: 0.025).map { $0 }
        func paperShareAt(_ t: Int) -> Double {
            var paper = 0, valid = 0
            for s in positions {
                let p = CGPoint(x: a.x + (b.x - a.x) * s + normal.0 * Double(t), y: a.y + (b.y - a.y) * s + normal.1 * Double(t))
                guard let (brightness, saturation) = sample(rgb, p) else { continue }
                // Marker und Haut verdecken die Kante nur: Diese Stellen sagen nichts darüber, wo das Papier beginnt.
                if isObstacle(rgb, p) { continue }
                valid += 1
                if brightness >= 0.72 * reference, saturation <= 0.28 { paper += 1 }
            }
            return valid >= 8 ? Double(paper) / Double(valid) : 0
        }
        if paperShareAt(0) >= paperShare && paperShareAt(2) >= paperShare { return 0 }
        // Eine Verschiebung von ein, zwei Pixeln ist Rauschen an der Kante (Antialiasing) und bleibt aus.
        for t in 1...limit where paperShareAt(t) >= paperShare && paperShareAt(min(limit, t + 3)) >= paperShare { return t + 1 > 2 ? t + 1 : 0 }
        return 0
    }

    /// Ob an der Stelle ein Marker (gelb) oder Haut liegt.
    private static func isObstacle(_ rgb: RGBBitmap, _ p: CGPoint) -> Bool {
        let x = Int(p.x.rounded()), y = Int(p.y.rounded())
        guard x >= 0, y >= 0, x < rgb.width, y < rgb.height else { return false }
        let i = (y * rgb.width + x) * 4
        return HandDetector.isMarkerYellow(r: rgb.pixels[i], g: rgb.pixels[i + 1], b: rgb.pixels[i + 2])
            || HandDetector.isSkin(r: rgb.pixels[i], g: rgb.pixels[i + 1], b: rgb.pixels[i + 2])
    }

    /// Helligkeit (größter Kanal, 0…255) und Sättigung (0…1) an einer Stelle des Messbildes.
    private static func sample(_ rgb: RGBBitmap, _ p: CGPoint) -> (Double, Double)? {
        let x = Int(p.x.rounded()), y = Int(p.y.rounded())
        guard x >= 0, y >= 0, x < rgb.width, y < rgb.height else { return nil }
        let i = (y * rgb.width + x) * 4
        let r = Double(rgb.pixels[i]), g = Double(rgb.pixels[i + 1]), b = Double(rgb.pixels[i + 2])
        let top = max(r, g, b)
        return (top, top > 0 ? (top - min(r, g, b)) / top : 0)
    }
}
