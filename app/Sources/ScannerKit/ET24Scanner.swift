import AVFoundation
import CUVC
import CoreImage
import Foundation

/// Umsetzung für den CZUR ET24 Pro (USB 04fc:6333) über AVFoundation und IOKit.
/// Hintergrund und Stolpersteine: docs/hardware-access.adoc.
public final class ET24Scanner: ScannerPort, @unchecked Sendable {
    private static let vendorToken = "VendorID_1276"
    private static let productToken = "ProductID_25395"

    private let busy = BusyFlag()

    public init() {}

    // MARK: ScannerPort

    public func connect() async throws -> DeviceInfo {
        try await Self.requestAccess()
        guard let device = Self.findDevice() else { throw ScannerError.deviceNotFound }
        return DeviceInfo(name: device.localizedName, identifier: device.uniqueID)
    }

    public func availableFormats() async throws -> [ScanFormat] {
        guard let device = Self.findDevice() else { throw ScannerError.deviceNotFound }
        let formats = Set(device.formats.map { format -> ScanFormat in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return ScanFormat(width: Int(d.width), height: Int(d.height))
        })
        return formats.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    public func openSession(format: ScanFormat, settings: CaptureSettings) async throws -> any ScanSession {
        guard busy.acquire() else { throw ScannerError.deviceBusy }
        var restore: (@Sendable () -> Void)?
        do {
            try await Self.requestAccess()
            guard let device = Self.findDevice() else { throw ScannerError.deviceNotFound }
            let info = DeviceInfo(name: device.localizedName, identifier: device.uniqueID)
            restore = try Self.applySharpness(settings.sharpness)
            Trace.log("open: Schärfe gesetzt")
            let session = LiveSession(
                device: info, format: format, settings: settings,
                onClosed: { [busy, restore] in
                    restore?()
                    busy.release()
                }
            )
            try await session.start()
            Trace.log("open: Strom läuft")
            return session
        } catch {
            restore?()
            busy.release()
            throw error
        }
    }

    // MARK: Hilfen

    private static func requestAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) { return }
            throw ScannerError.cameraAccessDenied
        default: throw ScannerError.cameraAccessDenied
        }
    }

    static func findDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
            .first { $0.modelID.contains(vendorToken) && $0.modelID.contains(productToken) }
    }

    /// Setzt die Schärfe und liefert eine Funktion, die den Standardwert des Geräts wiederherstellt.
    /// Der Standardwert statt des vorherigen Werts, damit ein Absturz mit Schärfe 0 nicht zum „vorherigen“ Wert wird.
    private static func applySharpness(_ wanted: Int?) throws -> @Sendable () -> Void {
        guard let wanted else { return {} }
        var current: Int32 = 0, min: Int32 = 0, max: Int32 = 0, defaultValue: Int32 = 0
        let readStatus = cuvc_get_sharpness(&current, &min, &max, &defaultValue)
        guard readStatus == 0 else { throw ScannerError.controlFailed(name: "Schärfe", code: Int(readStatus)) }
        let setStatus = cuvc_set_sharpness(Int32(wanted))
        guard setStatus == 0 else { throw ScannerError.controlFailed(name: "Schärfe", code: Int(setStatus)) }
        let restoreValue = defaultValue
        return { _ = cuvc_set_sharpness(restoreValue) }
    }
}

/// Verhindert zwei gleichzeitige Sitzungen. Synchron, damit die Sperre nicht über ein `await` gehalten wird.
private final class BusyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isBusy = false

    func acquire() -> Bool {
        lock.withLock {
            if isBusy { return false }
            isBusy = true
            return true
        }
    }

    func release() {
        lock.withLock { isBusy = false }
    }
}

private struct UncheckedBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Dauerhafte Sitzung im Aufnahmeformat. Jedes Bild des Stroms speist die Vorschau (verkleinert),
/// ein Scan nimmt das nächste Bild in voller Größe.
private final class LiveSession: NSObject, ScanSession, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let device: DeviceInfo
    let format: ScanFormat
    let previewFrames: AsyncStream<PreviewFrame>
    let connectionLost: AsyncStream<ScannerError>

    /// Breite der Vorschaubilder in Pixeln.
    private static let previewWidth = 1536.0
    /// So lange darf kein Bild kommen, bevor die Verbindung als verloren gilt. Der Strom liefert sonst viele Bilder je Sekunde;
    /// bleibt er stehen, ist das Gerät weg oder hängt, auch wenn macOS keine Meldung schickt.
    private static let stallLimit: TimeInterval = 5

    private let settings: CaptureSettings
    private let onClosed: @Sendable () -> Void
    private let previewContinuation: AsyncStream<PreviewFrame>.Continuation
    private let lostContinuation: AsyncStream<ScannerError>.Continuation
    private let queue = DispatchQueue(label: "scanutil.et24.session")
    private let avSession = AVCaptureSession()
    private let ciContext = CIContext()
    private let lock = NSLock()

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var isClosed = false
    private var waiters: [UUID: CheckedContinuation<UncheckedBuffer, Error>] = [:]
    private var frameCount = 0
    private var avDevice: AVCaptureDevice?
    private var lostReported = false
    private var lastFrame = Date()
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private var formatGuard = FrameFormatGuard()

    init(device: DeviceInfo, format: ScanFormat, settings: CaptureSettings, onClosed: @escaping @Sendable () -> Void) {
        self.device = device
        self.format = format
        self.settings = settings
        self.onClosed = onClosed
        let (stream, continuation) = AsyncStream<PreviewFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        previewFrames = stream
        previewContinuation = continuation
        let (lostStream, lostContinuation) = AsyncStream<ScannerError>.makeStream()
        connectionLost = lostStream
        self.lostContinuation = lostContinuation
        super.init()
    }

    // MARK: Start

    /// Startet den Strom und kehrt zurück, sobald das erste Bild in der Aufnahmegröße da ist.
    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock { readyContinuation = cont }
            queue.async { [self] in
                do { try configure() } catch { failStart(error) }
            }
            queue.asyncAfter(deadline: .now() + 20) { [self] in failStart(ScannerError.timeout) }
        }
        startMonitoring()
    }

    private func configure() throws {
        guard let avDevice = AVCaptureDevice(uniqueID: device.identifier) else { throw ScannerError.deviceNotFound }
        guard let avFormat = avDevice.formats.first(where: {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return Int(d.width) == format.width && Int(d.height) == format.height
        }) else { throw ScannerError.formatUnavailable(format) }

        lock.withLock { self.avDevice = avDevice }
        let input = try AVCaptureDeviceInput(device: avDevice)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        guard avSession.canAddInput(input), avSession.canAddOutput(output) else { throw ScannerError.deviceNotFound }
        avSession.addInput(input)
        avSession.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        avSession.startRunning()

        // macOS setzt das Format beim Start auf das Preset zurück: erst danach das gewünschte setzen.
        try avDevice.lockForConfiguration()
        avDevice.activeFormat = avFormat
        avDevice.unlockForConfiguration()
        Trace.log("session: Format gesetzt")
    }

    private func failStart(_ error: Error) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let c = readyContinuation
            readyContinuation = nil
            return c
        }
        guard let cont else { return }
        avSession.stopRunning()
        previewContinuation.finish()
        cont.resume(throwing: error)
    }

    // MARK: Bilder

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Bilder vor dem Formatwechsel haben noch die Preset-Größe und zählen nicht.
        guard CVPixelBufferGetWidth(buffer) == format.width, CVPixelBufferGetHeight(buffer) == format.height else { return }
        // Löst der Scanner selbst aus (Taste am Gerät, Fußtaster), liefert er kurz Bilder in anderer Form, die als Bildsalat
        // ankommen. Die gelten nicht, auch nicht für die Vorschau.
        let shape = FrameFormat(pixelFormat: CVPixelBufferGetPixelFormatType(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                planes: CVPixelBufferGetPlaneCount(buffer), dataSize: CVPixelBufferGetDataSize(buffer))
        let (accepted, rejectedSoFar) = lock.withLock { () -> (Bool, Int) in
            let before = formatGuard.rejected
            let ok = formatGuard.accept(shape)
            return (ok, formatGuard.rejected - before)
        }
        if rejectedSoFar > 0 { Trace.log("session: Bild verworfen (\(shape))") }
        guard accepted else { return }

        let (ready, pending, closed) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, [CheckedContinuation<UncheckedBuffer, Error>], Bool) in
            frameCount += 1
            lastFrame = Date()
            let r = readyContinuation
            readyContinuation = nil
            isReady = true
            let p = Array(waiters.values)
            waiters.removeAll()
            return (r, p, isClosed)
        }
        guard !closed else { return }
        if frameCount == 1 { Trace.log("session: erstes Bild in Aufnahmegröße") }
        ready?.resume()
        for waiter in pending { waiter.resume(returning: UncheckedBuffer(buffer: buffer)) }

        // Vorschau: auf Vorschaubreite verkleinern. Das Original bleibt unberührt.
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = Self.previewWidth / image.extent.width
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cg = ciContext.createCGImage(small, from: small.extent) {
            previewContinuation.yield(PreviewFrame(image: cg))
        }
    }

    // MARK: Verlust der Verbindung

    /// Beobachtet das Gerät auf drei Wegen: macOS meldet das Abziehen, die Sitzung meldet einen Laufzeitfehler,
    /// und eine Wache schlägt an, wenn länger kein Bild kommt.
    private func startMonitoring() {
        let device = lock.withLock { avDevice }
        let center = NotificationCenter.default
        let disconnected = center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
            Trace.log("session: Gerät getrennt")
            self?.markLost()
        }
        let failed = center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: avSession, queue: nil) { [weak self] _ in
            Trace.log("session: Laufzeitfehler")
            self?.markLost()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let silent = Date().timeIntervalSince(lock.withLock { lastFrame })
            if silent > Self.stallLimit {
                Trace.log("session: seit \(Int(silent)) s kein Bild")
                markLost()
            }
        }
        lock.withLock {
            observers = [disconnected, failed]
            watchdog = timer
        }
        timer.resume()
    }

    /// Das Gerät ist weg. Wartende Aufnahmen scheitern sofort statt nach zehn Sekunden, und der Verlust wird einmal gemeldet.
    private func markLost() {
        let (first, pending, starting) = lock.withLock { () -> (Bool, [CheckedContinuation<UncheckedBuffer, Error>], Bool) in
            if lostReported || isClosed { return (false, [], false) }
            lostReported = true
            let p = Array(waiters.values)
            waiters.removeAll()
            return (true, p, readyContinuation != nil)
        }
        guard first else { return }
        for waiter in pending { waiter.resume(throwing: ScannerError.deviceNotFound) }
        if starting { failStart(ScannerError.deviceNotFound) }
        stopMonitoring()
        lostContinuation.yield(.deviceNotFound)
        lostContinuation.finish()
    }

    private func stopMonitoring() {
        let (tokens, timer) = lock.withLock { () -> ([NSObjectProtocol], DispatchSourceTimer?) in
            let t = observers, w = watchdog
            observers = []
            watchdog = nil
            return (t, w)
        }
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        timer?.cancel()
    }

    // MARK: ScanSession

    func capture() async throws -> Capture {
        let requested = Date()
        Trace.log("capture: Auslöser")
        let id = UUID()
        let frame: UncheckedBuffer = try await withCheckedThrowingContinuation { cont in
            let alreadyClosed = lock.withLock { () -> Bool in
                if isClosed { return true }
                waiters[id] = cont
                return false
            }
            if alreadyClosed {
                cont.resume(throwing: ScannerError.deviceNotFound)
                return
            }
            queue.asyncAfter(deadline: .now() + 10) { [self] in
                let timedOut = lock.withLock { waiters.removeValue(forKey: id) }
                timedOut?.resume(throwing: ScannerError.timeout)
            }
        }
        Trace.log("capture: Bild erhalten")
        let encoded = try await Task.detached(priority: .userInitiated) { [ciContext] in
            let image = CIImage(cvPixelBuffer: frame.buffer)
            guard let cg = ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
                throw ScannerError.encodingFailed
            }
            return (try PNGEncoding.data(from: cg), cg.width, cg.height)
        }.value
        Trace.log("capture: PNG kodiert (\(encoded.0.count / 1000) kB)")
        return Capture(
            imageData: encoded.0, width: encoded.1, height: encoded.2,
            metadata: CaptureMetadata(device: device, requestedFormat: format, capturedAt: requested, sharpness: settings.sharpness)
        )
    }

    func close() async {
        let (first, pending) = lock.withLock { () -> (Bool, [CheckedContinuation<UncheckedBuffer, Error>]) in
            if isClosed { return (false, []) }
            isClosed = true
            let p = Array(waiters.values)
            waiters.removeAll()
            return (true, p)
        }
        guard first else { return }
        for waiter in pending { waiter.resume(throwing: ScannerError.deviceNotFound) }
        stopMonitoring()
        lostContinuation.finish()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                avSession.stopRunning()
                previewContinuation.finish()
                onClosed()
                done.resume()
            }
        }
    }
}

/// Abschaltbare Zeitmessung. Ausgabe auf stderr, wenn `SCANUTIL_TRACE` gesetzt ist.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["SCANUTIL_TRACE"] != nil
    private static let start = ContinuousClock.now

    static func log(_ label: String) {
        guard enabled else { return }
        let d = ContinuousClock.now - start
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        FileHandle.standardError.write(Data(String(format: "[trace %8.0f ms] %@\n", ms, label).utf8))
    }
}
