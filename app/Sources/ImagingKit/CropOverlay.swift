import CoreGraphics
import Foundation

/// Zeichnet Zuschnittsrahmen auf ein Bild, damit man sieht, was die App aus einer Seite machen würde.
public enum CropOverlay {
    public enum Style: Sendable {
        /// Der Rahmen, den das PDF verwendet, die Automatik war sich sicher.
        case used
        /// Der Rahmen, den das PDF verwendet, obwohl die Automatik unsicher war oder nur die Bildhälfte gilt.
        case uncertain
        /// Die andere Seite derselben Doppelseite: nur zur Orientierung, gestrichelt.
        case neighbour
    }

    public struct Frame: Sendable {
        public var quad: Quad
        public var style: Style
        public init(quad: Quad, style: Style) { self.quad = quad; self.style = style }
    }

    /// Das Bild mit den Rahmen. Außerhalb des ersten Rahmens in Stil `.used` oder `.uncertain` wird es abgedunkelt: Was dunkel
    /// ist, fällt weg. `nil`, wenn kein Bild entsteht.
    public static func draw(_ frames: [Frame], on image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = Double(width), h = Double(height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        func path(_ quad: Quad) -> CGPath {
            let p = CGMutablePath()
            func point(_ n: NormalizedPoint) -> CGPoint { CGPoint(x: n.x * w, y: (1 - n.y) * h) }   // Ursprung unten links
            p.move(to: point(quad.topLeft))
            p.addLine(to: point(quad.topRight)); p.addLine(to: point(quad.bottomRight)); p.addLine(to: point(quad.bottomLeft))
            p.closeSubpath()
            return p
        }

        if let main = frames.first(where: { $0.style != .neighbour }) {
            let outside = CGMutablePath()
            outside.addRect(CGRect(x: 0, y: 0, width: w, height: h))
            outside.addPath(path(main.quad))
            context.setFillColor(CGColor(gray: 0, alpha: 0.45))
            context.addPath(outside)
            context.fillPath(using: .evenOdd)
        }
        let line = max(2, max(w, h) / 350)
        for frame in frames {
            context.saveGState()
            context.setLineWidth(frame.style == .neighbour ? line * 0.7 : line)
            switch frame.style {
            case .used: context.setStrokeColor(CGColor(red: 0.1, green: 0.8, blue: 0.3, alpha: 1))
            case .uncertain: context.setStrokeColor(CGColor(red: 1, green: 0.6, blue: 0, alpha: 1))
            case .neighbour:
                context.setStrokeColor(CGColor(gray: 0.85, alpha: 0.9))
                context.setLineDash(phase: 0, lengths: [line * 4, line * 3])
            }
            context.addPath(path(frame.quad))
            context.strokePath()
            context.restoreGState()
        }
        return context.makeImage()
    }
}
