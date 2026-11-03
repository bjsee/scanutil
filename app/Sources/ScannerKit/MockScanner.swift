import CoreGraphics
import Foundation

/// Ein vom Mock gelieferte Aufnahme: kodiertes Bild und seine Maße.
public struct MockImage: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int

    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
}

/// Scanner ohne Hardware für Tests und Entwicklung.
/// Liefert ein künstliches Testbild und merkt sich die Aufrufe.
public final class MockScanner: ScannerPort, @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public let format: ScanFormat
        public let settings: CaptureSettings
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var opened = 0
    private var closed = 0
    private let formats: [ScanFormat]
    private let device: DeviceInfo
    private let failure: ScannerError?
    private let captureFailure: ScannerError?
    private let clock: @Sendable () -> Date
    private let imageProvider: (@Sendable (ScanFormat) throws -> MockImage)?
    fileprivate let previewsEnabled: Bool
    fileprivate let stillPreview: Bool
    private let appearsAfter: TimeInterval
    private var switchedOn: Bool
    private let connectDelay: Duration
    private let created = ProcessInfo.processInfo.systemUptime
    private var attempts = 0

    public init(
        formats: [ScanFormat] = [ScanFormat(width: 640, height: 480), ScanFormat(width: 320, height: 240)],
        device: DeviceInfo = DeviceInfo(name: "Mock-Scanner", identifier: "mock"),
        failure: ScannerError? = nil,
        captureFailure: ScannerError? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        imageProvider: (@Sendable (ScanFormat) throws -> MockImage)? = nil,
        previewsEnabled: Bool = true,
        stillPreview: Bool = false,
        appearsAfter: TimeInterval = 0,
        startsSwitchedOff: Bool = false,
        connectDelay: Duration = .zero
    ) {
        self.connectDelay = connectDelay
        self.appearsAfter = appearsAfter
        switchedOn = !startsSwitchedOff
        self.previewsEnabled = previewsEnabled
        self.stillPreview = stillPreview
        self.formats = formats
        self.device = device
        self.failure = failure
        self.captureFailure = captureFailure
        self.clock = clock
        self.imageProvider = imageProvider
    }

    /// Aufnahmen in der Reihenfolge ihres Auslösens.
    public var calls: [Call] { lock.withLock { recordedCalls } }
    public var openedSessions: Int { lock.withLock { opened } }
    public var closedSessions: Int { lock.withLock { closed } }
    /// Wie oft `connect()` aufgerufen wurde, auch erfolglos.
    public var connectAttempts: Int { lock.withLock { attempts } }

    /// Ob das Gerät schon „eingeschaltet“ ist. Mit `appearsAfter` taucht es erst nach dieser Zeit auf,
    /// wie ein Scanner, den man nach dem Start der App einschaltet.
    private var isPresent: Bool { lock.withLock { switchedOn } && ProcessInfo.processInfo.systemUptime - created >= appearsAfter }

    /// Schaltet das Gerät ein oder aus, für Tests, die den Zeitpunkt genau bestimmen müssen.
    public func setSwitchedOn(_ on: Bool) { lock.withLock { switchedOn = on } }

    public func connect() async throws -> DeviceInfo {
        lock.withLock { attempts += 1 }
        // Ein Versuch, der dauert: damit Tests Ereignisse mitten in einem Versuch auslösen können.
        // Ein Abbruch beendet das Warten, nicht den Versuch, wie bei einem echten Gerät.
        if connectDelay > .zero { try? await Task.sleep(for: connectDelay) }
        if let failure { throw failure }
        guard isPresent else { throw ScannerError.deviceNotFound }
        return device
    }

    public func availableFormats() async throws -> [ScanFormat] {
        if let failure { throw failure }
        guard isPresent else { throw ScannerError.deviceNotFound }
        return formats
    }

    public func openSession(format: ScanFormat, settings: CaptureSettings) async throws -> any ScanSession {
        if let failure { throw failure }
        guard isPresent else { throw ScannerError.deviceNotFound }
        guard formats.contains(format) else { throw ScannerError.formatUnavailable(format) }
        lock.withLock { opened += 1 }
        return MockSession(owner: self, device: device, format: format, settings: settings)
    }

    fileprivate func record(_ call: Call) { lock.withLock { recordedCalls.append(call) } }
    fileprivate func recordClose() { lock.withLock { closed += 1 } }
    fileprivate var captureError: ScannerError? { captureFailure }
    fileprivate var now: Date { clock() }

    /// Bild der nächsten Aufnahme: das vom Lieferanten vorgegebene oder ein künstlicher Verlauf.
    fileprivate func image(for format: ScanFormat) throws -> MockImage {
        if let imageProvider { return try imageProvider(format) }
        return MockImage(data: try Self.testImage(width: format.width, height: format.height), width: format.width, height: format.height)
    }

    fileprivate static func testImage(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ScannerError.encodingFailed }
        for x in 0..<width {
            context.setFillColor(gray: CGFloat(x) / CGFloat(width), alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        guard let image = context.makeImage() else { throw ScannerError.encodingFailed }
        return try PNGEncoding.data(from: image)
    }
}

private final class MockSession: ScanSession, @unchecked Sendable {
    let device: DeviceInfo
    let format: ScanFormat
    let previewFrames: AsyncStream<PreviewFrame>

    private let owner: MockScanner
    private let settings: CaptureSettings
    private let previewTask: Task<Void, Never>
    private let lock = NSLock()
    private var isClosed = false

    init(owner: MockScanner, device: DeviceInfo, format: ScanFormat, settings: CaptureSettings) {
        self.owner = owner
        self.device = device
        self.format = format
        self.settings = settings
        let (stream, continuation) = AsyncStream<PreviewFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        previewFrames = stream
        previewTask = Task {
            var shade: CGFloat = 0
            while !Task.isCancelled {
                if owner.previewsEnabled, let image = Self.previewImage(shade: shade) { continuation.yield(PreviewFrame(image: image)) }
                // Eine stehende Vorschau ändert sich nie: wie ein ruhig liegendes Buch, die Auto-Auslösung sieht nur Ruhe.
                if !owner.stillPreview { shade = (shade + 0.1).truncatingRemainder(dividingBy: 1) }
                try? await Task.sleep(for: .milliseconds(30))
            }
            continuation.finish()
        }
    }

    func capture() async throws -> Capture {
        if let error = owner.captureError { throw error }
        guard !lock.withLock({ isClosed }) else { throw ScannerError.deviceNotFound }
        owner.record(.init(format: format, settings: settings))
        let image = try owner.image(for: format)
        return Capture(
            imageData: image.data, width: image.width, height: image.height,
            metadata: CaptureMetadata(device: device, requestedFormat: format, capturedAt: owner.now, sharpness: settings.sharpness)
        )
    }

    func close() async {
        let first = lock.withLock { () -> Bool in
            let was = isClosed
            isClosed = true
            return !was
        }
        guard first else { return }
        previewTask.cancel()
        owner.recordClose()
    }

    private static func previewImage(shade: CGFloat) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: shade, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        return context.makeImage()
    }
}
