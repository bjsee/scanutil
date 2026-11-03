import AppKit
import ImagingKit
import SwiftUI

/// Eingabe des Nutzers für den Zoom, unabhängig vom Gerät (Mausrad, Trackpad, Pinch).
enum ZoomInput: Equatable {
    /// Zoomen um einen Faktor, um den Mauszeiger.
    case zoom(factor: Double)
    /// Das Bild verschieben, etwa mit zwei Fingern auf dem Trackpad.
    case pan(CGSize)
}

extension Corrections {
    /// Stellt fest, ob sich Korrekturen geändert haben, ohne dass `revision` es zeigt (die Automatik setzt sie ohne Zählung).
    /// Mit festen Schlüsselreihenfolge: ohne `sortedKeys` kodiert derselbe Wert mal so, mal so, der Schlüssel würde sich ständig
    /// „ändern“, und das nachgeladene Bild in voller Auflösung würde bei jeder Neuberechnung der Ansicht verworfen.
    var cacheKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// Ein Bild mit Zoom: Knöpfe, Mausrad und Pinch (um den Mauszeiger), Ziehen zum Verschieben, Doppelklick wechselt zwischen
/// Einpassen und Zoom.
///
/// Verkleinerte Ansichten werden beim Hineinzoomen unscharf. Mit `fullResolution` lädt die Ansicht ab etwa 1,5-fachem
/// Zoom das Bild in voller Auflösung nach und tauscht es aus.
struct ZoomableImageView: View {
    let image: CGImage
    /// Vorne in den Kennungen der Bedienelemente: `<identifier>-zoom-in` und so weiter.
    let identifier: String
    /// Wie viele Pixel des Originals ein Pixel von `image` darstellt. Daran hängen die Prozentanzeige und „1:1“:
    /// 100 % heißt ein Pixel des Originals je Bildschirmpixel. Ohne Angabe gilt `image` selbst.
    var pixelScale = 1.0
    var fullResolution: (@MainActor () async -> CGImage?)?
    /// Ändert sich der Schlüssel (etwa weil Korrekturen sich änderten), ist das nachgeladene Bild veraltet.
    var fullResolutionKey = ""

    @State private var zoom = ZoomState()
    @State private var dragStart: CGSize?
    @State private var detail: CGImage?
    @State private var isLoadingDetail = false

    /// Ab diesem Zoom wird das Bild in voller Auflösung nachgeladen.
    private static let detailThreshold = 1.5

    private struct LoadRequest: Hashable {
        let key: String
        let wanted: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = Metrics(image: image, view: geometry.size, pixelScale: pixelScale, backing: backingScale)
            ZoomableImageContent(
                shown: detail ?? image, metrics: metrics, zoom: zoom, identifier: identifier,
                hasDetail: detail != nil, isLoadingDetail: isLoadingDetail,
                zoomIn: { apply(metrics) { $0.zoom(by: ZoomState.buttonStep, fit: metrics.fit, view: metrics.view, maxScale: metrics.maxScale) } },
                zoomOut: { apply(metrics) { $0.zoom(by: 1 / ZoomState.buttonStep, fit: metrics.fit, view: metrics.view, maxScale: metrics.maxScale) } },
                fitToView: { apply(metrics) { $0.reset() } },
                actualSize: { apply(metrics) { $0.setScale(metrics.actualScale, fit: metrics.fit, view: metrics.view, maxScale: metrics.maxScale) } }
            )
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragStart == nil { dragStart = zoom.offset }
                        let start = dragStart ?? .zero
                        zoom.setOffset(CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height),
                                       fit: metrics.fit, view: metrics.view)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    let anchor = CGPoint(x: value.location.x - metrics.view.width / 2, y: value.location.y - metrics.view.height / 2)
                    if zoom.isZoomed { zoom.reset() } else {
                        // Auf 1:1, wenn das eine sinnvolle Vergrößerung ist, sonst dreifach.
                        let target = metrics.actualScale > 1.2 && metrics.actualScale <= metrics.maxScale ? metrics.actualScale : 3
                        zoom.setScale(target, around: anchor, fit: metrics.fit, view: metrics.view, maxScale: metrics.maxScale)
                    }
                }
            )
            .background(ZoomEventCatcher { input, anchor in handle(input, anchor: anchor, metrics: metrics) })
            .task(id: LoadRequest(key: fullResolutionKey, wanted: zoom.scale > Self.detailThreshold)) {
                await loadDetailIfNeeded()
            }
            .onChange(of: fullResolutionKey) { detail = nil }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Eingaben

    private func apply(_ metrics: Metrics, _ change: (inout ZoomState) -> Void) {
        change(&zoom)
        zoom.clamp(fit: metrics.fit, view: metrics.view)
    }

    private func handle(_ input: ZoomInput, anchor: CGPoint, metrics: Metrics) -> Bool {
        switch input {
        case .zoom(let factor):
            zoom.zoom(by: factor, around: anchor, fit: metrics.fit, view: metrics.view, maxScale: metrics.maxScale)
            return true
        case .pan(let delta):
            guard zoom.isZoomed else { return false }
            zoom.pan(by: delta, fit: metrics.fit, view: metrics.view)
            return true
        }
    }

    /// Lädt das Bild in voller Auflösung, wenn weit genug hineingezoomt ist. Kurz verzögert, damit ein Regler, der die
    /// Korrekturen ändert, nicht bei jedem Schritt ein 24-Megapixel-Bild berechnen lässt.
    private func loadDetailIfNeeded() async {
        guard zoom.scale > Self.detailThreshold, let fullResolution, detail == nil else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isLoadingDetail = true
        let loaded = await fullResolution()
        isLoadingDetail = false
        if !Task.isCancelled { detail = loaded }
    }

    private var backingScale: Double { Double(NSApp.keyWindow?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

    /// Alle Größen, die Zoom und Anzeige gemeinsam brauchen, an einer Stelle gerechnet.
    struct Metrics {
        let view: CGSize
        let fit: CGSize
        let backing: Double
        let referencePixelWidth: Double
        let actualScale: Double
        let maxScale: Double

        init(image: CGImage, view: CGSize, pixelScale: Double, backing: Double) {
            self.view = view
            self.backing = backing
            fit = ZoomState.fitSize(image: CGSize(width: image.width, height: image.height), in: view)
            referencePixelWidth = Double(image.width) * pixelScale
            actualScale = ZoomState.actualScale(referencePixelWidth: referencePixelWidth, fitWidth: fit.width, backingScale: backing)
            maxScale = ZoomState.maxScale(actualScale: actualScale)
        }

        func percent(scale: Double) -> Double {
            ZoomState.percent(scale: scale, referencePixelWidth: referencePixelWidth, fitWidth: fit.width, backingScale: backing)
        }
    }
}

/// Die Darstellung ohne Ereignisse und Gesten, damit sie sich einzeln rendern und prüfen lässt.
struct ZoomableImageContent: View {
    let shown: CGImage
    let metrics: ZoomableImageView.Metrics
    let zoom: ZoomState
    let identifier: String
    let hasDetail: Bool
    let isLoadingDetail: Bool
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let fitToView: () -> Void
    let actualSize: () -> Void

    var body: some View {
        let percent = metrics.percent(scale: zoom.scale)
        ZStack {
            Image(decorative: shown, scale: 1)
                .resizable()
                // Ab einem Bildpixel je Bildschirmpixel zeigt die Vergrößerung die Pixel scharf statt verwaschen.
                .interpolation(percent >= 100 ? .none : .high)
                .frame(width: metrics.fit.width, height: metrics.fit.height)
                .scaleEffect(zoom.scale)
                .offset(zoom.offset)
        }
        .frame(width: metrics.view.width, height: metrics.view.height)
        .clipped()
        .contentShape(Rectangle())
        .overlay(alignment: .bottomTrailing) { controls(percent: percent) }
    }

    private func controls(percent: Double) -> some View {
        HStack(spacing: 6) {
            if isLoadingDetail {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Volle Auflösung wird geladen")
                    .accessibilityIdentifier("\(identifier)-zoom-loading")
            } else if hasDetail {
                Text("volle Auflösung").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifier)-zoom-detail")
            }
            Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass") }
                .disabled(!zoom.isZoomed)
                .help("Verkleinern")
                .accessibilityLabel("Verkleinern")
                .accessibilityIdentifier("\(identifier)-zoom-out")
            Text("\(Int(percent.rounded())) %")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 44)
                .accessibilityLabel("Zoom")
                .accessibilityValue("\(Int(percent.rounded())) %")
                .accessibilityIdentifier("\(identifier)-zoom-level")
            Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }
                .disabled(zoom.scale >= metrics.maxScale - 0.001)
                .help("Vergrößern")
                .accessibilityLabel("Vergrößern")
                .accessibilityIdentifier("\(identifier)-zoom-in")
            Button(action: fitToView) { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .disabled(!zoom.isZoomed)
                .help("Einpassen")
                .accessibilityLabel("Einpassen")
                .accessibilityIdentifier("\(identifier)-zoom-fit")
            Button(action: actualSize) { Text("1:1").font(.caption.bold()) }
                // Zeigt das eingepasste Bild schon mehr als 100 %, liegt 1:1 unter dem Einpassen, und kleiner zoomt man nicht.
                .disabled(metrics.actualScale <= 1.001)
                .help(metrics.actualScale <= 1.001 ? "Das Bild ist eingepasst bereits größer als 1:1" : "Ein Bildpixel je Bildschirmpixel")
                .accessibilityLabel("Originalgröße")
                .accessibilityIdentifier("\(identifier)-zoom-actual")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .padding(6)
    }
}

/// Fängt Mausrad, Trackpad und Pinch über der Ansicht ab. Ein lokaler Beobachter statt einer Überlagerung, damit Klicken und
/// Ziehen der SwiftUI-Gesten darunter unberührt bleiben.
///
/// Mausrad und ⌘/⌥ mit Trackpad zoomen um den Mauszeiger, Pinch zoomt, zwei Finger verschieben das Bild, sobald es gezoomt ist.
struct ZoomEventCatcher: NSViewRepresentable {
    let handler: @MainActor (ZoomInput, CGPoint) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.handler = handler }

    final class CatcherView: NSView {
        var handler: (@MainActor (ZoomInput, CGPoint) -> Bool)?
        /// `nonisolated(unsafe)`, weil `deinit` ihn lesen muss. Gesetzt und gelesen wird er sonst nur im Hauptthread.
        private nonisolated(unsafe) var token: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        deinit { if let token { NSEvent.removeMonitor(token) } }

        private func removeMonitor() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }

        /// Die Ansicht selbst nimmt keine Mausereignisse an.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }
            let anchor = CGPoint(x: point.x - bounds.midX, y: isFlipped ? point.y - bounds.midY : -(point.y - bounds.midY))
            guard let input = Self.input(for: event), let handler else { return event }
            return MainActor.assumeIsolated { handler(input, anchor) } ? nil : event
        }

        static func input(for event: NSEvent) -> ZoomInput? {
            switch event.type {
            case .magnify:
                return .zoom(factor: max(0.1, 1 + Double(event.magnification)))
            case .scrollWheel:
                let precise = event.hasPreciseScrollingDeltas
                let zooms = !precise || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
                if zooms {
                    // Ein Rastschritt des Mausrads vergrößert um 15 %, Trackpad mit ⌘ feiner.
                    let delta = max(-50, min(50, Double(event.scrollingDeltaY)))
                    guard delta != 0 else { return nil }
                    return .zoom(factor: pow(precise ? 1.01 : 1.15, delta))
                }
                return .pan(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            default:
                return nil
            }
        }
    }
}
