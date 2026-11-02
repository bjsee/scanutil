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

    public func previewFrames(format: ScanFormat) -> AsyncThrowingStream<PreviewFrame, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard busy.acquire() else {
                continuation.finish(throwing: ScannerError.deviceBusy)
                return
            }
            guard let device = Self.findDevice() else {
                busy.release()
                continuation.finish(throwing: ScannerError.deviceNotFound)
                return
            }
            let job = PreviewJob(deviceID: device.uniqueID, format: format, continuation: continuation, onStopped: { [busy] in busy.release() })
            continuation.onTermination = { _ in job.stop() }
            job.start()
        }
    }

    public func capture(format: ScanFormat, settings: CaptureSettings) async throws -> Capture {
        // Läuft noch die Vorschau, kurz auf deren Freigabe warten.
        var waited = 0
        while !busy.acquire() {
            guard waited < 60 else { throw ScannerError.deviceBusy }
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        defer { busy.release() }

        try await Self.requestAccess()
        guard let device = Self.findDevice() else { throw ScannerError.deviceNotFound }
        let info = DeviceInfo(name: device.localizedName, identifier: device.uniqueID)

        let restore = try Self.applySharpness(settings.sharpness)
        defer { restore() }

        let job = FrameJob(deviceID: device.uniqueID, format: format)
        let frame = try await job.run()
        return Capture(
            imageData: frame.png, width: frame.width, height: frame.height,
            metadata: CaptureMetadata(device: info, requestedFormat: format, capturedAt: Date(), sharpness: settings.sharpness)
        )
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

    private static func findDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
            .first { $0.modelID.contains(vendorToken) && $0.modelID.contains(productToken) }
    }

    /// Setzt die Schärfe und liefert eine Funktion, die den vorherigen Wert wiederherstellt.
    private static func applySharpness(_ wanted: Int?) throws -> () -> Void {
        guard let wanted else { return {} }
        var previous: Int32 = 0, min: Int32 = 0, max: Int32 = 0
        let readStatus = cuvc_get_sharpness(&previous, &min, &max)
        guard readStatus == 0 else { throw ScannerError.controlFailed(name: "Schärfe", code: Int(readStatus)) }
        let setStatus = cuvc_set_sharpness(Int32(wanted))
        guard setStatus == 0 else { throw ScannerError.controlFailed(name: "Schärfe", code: Int(setStatus)) }
        return { _ = cuvc_set_sharpness(previous) }
    }
}

/// Eine einzelne Aufnahme. Hält die AVFoundation-Objekte und löst die Fortsetzung genau einmal aus.
private final class FrameJob: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Frame: Sendable { let png: Data; let width: Int; let height: Int }

    /// Frames, die verworfen werden, bevor eines übernommen wird (Belichtung und Format müssen sich einpendeln).
    private static let framesToSkip = 8

    private let deviceID: String
    private let format: ScanFormat
    private let queue = DispatchQueue(label: "scanutil.et24.capture")
    private let session = AVCaptureSession()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Frame, Error>?
    private var received = 0
    private var finished = false

    init(deviceID: String, format: ScanFormat) {
        self.deviceID = deviceID
        self.format = format
    }

    func run() async throws -> Frame {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Frame, Error>) in
            lock.lock(); continuation = cont; lock.unlock()
            queue.async { [self] in
                do { try start() } catch { finish(.failure(error)) }
            }
            queue.asyncAfter(deadline: .now() + 30) { [self] in finish(.failure(ScannerError.timeout)) }
        }
    }

    private func start() throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw ScannerError.deviceNotFound }
        guard let avFormat = device.formats.first(where: {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return Int(d.width) == format.width && Int(d.height) == format.height
        }) else { throw ScannerError.formatUnavailable(format) }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { throw ScannerError.deviceNotFound }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.startRunning()

        // macOS setzt das Format beim Start auf das Preset zurück: erst danach das gewünschte setzen.
        try device.lockForConfiguration()
        device.activeFormat = avFormat
        device.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isFinished, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Nur Frames in der gewünschten Größe zählen, die Anfangsframes haben noch die Preset-Größe.
        guard CVPixelBufferGetWidth(buffer) == format.width, CVPixelBufferGetHeight(buffer) == format.height else { return }
        received += 1
        guard received > Self.framesToSkip else { return }
        do {
            let context = CIContext()
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
                throw ScannerError.encodingFailed
            }
            finish(.success(Frame(png: try PNGEncoding.data(from: cg), width: cg.width, height: cg.height)))
        } catch {
            finish(.failure(error))
        }
    }

    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    private func finish(_ result: Result<Frame, Error>) {
        lock.lock()
        guard !finished, let cont = continuation else { lock.unlock(); return }
        finished = true
        continuation = nil
        lock.unlock()
        session.stopRunning()
        cont.resume(with: result)
    }
}

/// Verhindert zwei gleichzeitige Aufnahmen. Synchron, damit die Sperre nicht über ein `await` gehalten wird.
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

/// Laufende Vorschau. Gibt das Gerät beim Stoppen frei und meldet das über `onStopped`.
private final class PreviewJob: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let deviceID: String
    private let format: ScanFormat
    private let continuation: AsyncThrowingStream<PreviewFrame, Error>.Continuation
    private let onStopped: @Sendable () -> Void
    private let queue = DispatchQueue(label: "scanutil.et24.preview")
    private let session = AVCaptureSession()
    private let context = CIContext()
    private let lock = NSLock()
    private var stopped = false

    init(deviceID: String, format: ScanFormat, continuation: AsyncThrowingStream<PreviewFrame, Error>.Continuation, onStopped: @escaping @Sendable () -> Void) {
        self.deviceID = deviceID
        self.format = format
        self.continuation = continuation
        self.onStopped = onStopped
    }

    func start() {
        queue.async { [self] in
            do { try configureAndRun() } catch {
                continuation.finish(throwing: error)
                stop()
            }
        }
    }

    private func configureAndRun() throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw ScannerError.deviceNotFound }
        guard let avFormat = device.formats.first(where: {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return Int(d.width) == format.width && Int(d.height) == format.height
        }) else { throw ScannerError.formatUnavailable(format) }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddInput(input), session.canAddOutput(output) else { throw ScannerError.deviceNotFound }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.startRunning()
        // Das Format muss nach dem Start gesetzt werden, siehe docs/hardware-access.adoc.
        try device.lockForConfiguration()
        device.activeFormat = avFormat
        device.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Frames in Preset-Größe (vor dem Formatwechsel) überspringen.
        guard CVPixelBufferGetWidth(buffer) == format.width else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = context.createCGImage(image, from: image.extent) else { return }
        continuation.yield(PreviewFrame(image: cg))
    }

    func stop() {
        let alreadyStopped = lock.withLock { () -> Bool in
            let was = stopped
            stopped = true
            return was
        }
        guard !alreadyStopped else { return }
        queue.async { [self] in
            session.stopRunning()
            onStopped()
        }
    }
}
