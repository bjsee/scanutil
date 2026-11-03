import CoreGraphics
import Foundation

/// Zustand und Rechnung eines Zooms in einem Bildausschnitt. Rein rechnerisch, ohne Oberfläche, damit sich die Regeln prüfen lassen.
///
/// `scale` ist der Zoom relativ zum Einpassen: 1 zeigt das ganze Bild, 2 die doppelte Größe. `offset` verschiebt das Bild
/// aus der Mitte, in Punkten der Ansicht, Ursprung in der Mitte, y nach unten. Ein Anker ist ein Punkt der Ansicht, ebenfalls
/// relativ zur Mitte.
struct ZoomState: Equatable {
    /// Kleiner als das Einpassen zoomt man nicht.
    static let minScale = 1.0
    /// Schrittweite der Knöpfe.
    static let buttonStep = 1.5

    private(set) var scale = 1.0
    private(set) var offset = CGSize.zero

    var isZoomed: Bool { scale > 1.001 }

    mutating func reset() {
        scale = 1
        offset = .zero
    }

    /// Größe des Bildes, wenn es in die Ansicht eingepasst ist.
    static func fitSize(image: CGSize, in view: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else { return .zero }
        let factor = min(view.width / image.width, view.height / image.height)
        return CGSize(width: image.width * factor, height: image.height * factor)
    }

    /// Obergrenze: mindestens achtfach, und so viel, dass 1:1 deutlich überschritten werden kann.
    static func maxScale(actualScale: Double) -> Double { max(8, actualScale * 3) }

    /// Der Zoom, bei dem ein Bildpixel genau einem Bildschirmpixel entspricht.
    /// - Parameters:
    ///   - referencePixelWidth: Breite des Bildes in Pixeln, auf die sich „1:1“ bezieht.
    ///   - fitWidth: Breite des eingepassten Bildes in Punkten.
    ///   - backingScale: Bildschirmpixel je Punkt (2 bei Retina).
    static func actualScale(referencePixelWidth: Double, fitWidth: Double, backingScale: Double) -> Double {
        guard referencePixelWidth > 0, fitWidth > 0, backingScale > 0 else { return 1 }
        return referencePixelWidth / (fitWidth * backingScale)
    }

    /// Zoom in Prozent der Bildpixel: 100 heißt ein Bildpixel je Bildschirmpixel.
    static func percent(scale: Double, referencePixelWidth: Double, fitWidth: Double, backingScale: Double) -> Double {
        guard referencePixelWidth > 0 else { return 0 }
        return fitWidth * scale * backingScale / referencePixelWidth * 100
    }

    /// Ändert den Zoom um einen Faktor, so dass der Bildpunkt unter dem Anker stehen bleibt.
    mutating func zoom(by factor: Double, around anchor: CGPoint = .zero, fit: CGSize, view: CGSize, maxScale: Double) {
        setScale(scale * factor, around: anchor, fit: fit, view: view, maxScale: maxScale)
    }

    /// Setzt den Zoom, so dass der Bildpunkt unter dem Anker stehen bleibt.
    mutating func setScale(_ target: Double, around anchor: CGPoint = .zero, fit: CGSize, view: CGSize, maxScale: Double) {
        let old = scale
        let new = min(max(target, Self.minScale), maxScale)
        guard old > 0, new.isFinite else { return }
        // Der Bildpunkt unter dem Anker: p = (anker − offset) / alt. Danach soll anker = offset' + p · neu gelten.
        let ratio = new / old
        offset = CGSize(width: anchor.x - (anchor.x - offset.width) * ratio, height: anchor.y - (anchor.y - offset.height) * ratio)
        scale = new
        clamp(fit: fit, view: view)
    }

    /// Verschiebt das Bild um `delta` Punkte.
    mutating func pan(by delta: CGSize, fit: CGSize, view: CGSize) {
        offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        clamp(fit: fit, view: view)
    }

    /// Setzt die Verschiebung, etwa beim Ziehen mit der Maus.
    mutating func setOffset(_ value: CGSize, fit: CGSize, view: CGSize) {
        offset = value
        clamp(fit: fit, view: view)
    }

    /// Das Bild darf nicht aus der Ansicht wandern: Ist es kleiner als die Ansicht, bleibt es in der Mitte,
    /// sonst darf höchstens der Überstand verschoben werden.
    mutating func clamp(fit: CGSize, view: CGSize) {
        func limit(_ shown: Double, _ available: Double) -> Double { max(0, (shown - available) / 2) }
        let lx = limit(fit.width * scale, view.width), ly = limit(fit.height * scale, view.height)
        offset = CGSize(width: min(max(offset.width, -lx), lx), height: min(max(offset.height, -ly), ly))
    }
}
