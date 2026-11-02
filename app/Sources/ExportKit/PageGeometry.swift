import ArchiveKit
import ImagingKit

/// Bestimmt, welche Korrekturen für den Export einer Seite gelten.
public enum PageGeometry {
    /// Hat die Seite einen eigenen, aktiven Zuschnitt, gilt er. Sonst ergibt sich bei `.left` und `.right`
    /// die jeweilige Hälfte des ganzen Bildes, bei `.whole` bleibt es unverändert.
    /// Drehung und Hauptschalter der Korrekturen bleiben, wie sie sind.
    public static func effectiveCorrections(for page: DocumentPage) -> Corrections {
        var corrections = page.corrections
        guard page.region != .whole else { return corrections }
        if corrections.crop.enabled, corrections.crop.quad != nil { return corrections }
        corrections.crop.quad = half(of: .full, region: page.region)
        corrections.crop.enabled = true
        // Der Hauptschalter aus bedeutet „Original unverändert“. Eine Hälfte ist aber immer nötig,
        // sonst stünden beide Seiten als Doppelseite im PDF; die Drehung bleibt dann aus.
        if !corrections.enabled { corrections.rotation.enabled = false }
        corrections.enabled = true
        return corrections
    }

    static func half(of quad: Quad, region: PageRegion) -> Quad {
        func mid(_ a: NormalizedPoint, _ b: NormalizedPoint) -> NormalizedPoint {
            NormalizedPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let top = mid(quad.topLeft, quad.topRight), bottom = mid(quad.bottomLeft, quad.bottomRight)
        switch region {
        case .whole: return quad
        case .left: return Quad(topLeft: quad.topLeft, topRight: top, bottomRight: bottom, bottomLeft: quad.bottomLeft)
        case .right: return Quad(topLeft: top, topRight: quad.topRight, bottomRight: quad.bottomRight, bottomLeft: bottom)
        }
    }
}
