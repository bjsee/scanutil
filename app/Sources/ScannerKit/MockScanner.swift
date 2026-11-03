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
    fileprivate let captureDelay: Duration
    private let scheduledUnplug: (after: TimeInterval, returnsAfter: TimeInterval)?
    private var unplugScheduled = false
    private var liveSessions: [MockSession] = []
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
        connectDelay: Duration = .zero,
        captureDelay: Duration = .zero,
        scheduledUnplug: (after: TimeInterval, returnsAfter: TimeInterval)? = nil
    ) {
        self.connectDelay = connectDelay
        self.captureDelay = captureDelay
        self.scheduledUnplug = scheduledUnplug
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

    /// Zieht das Gerät ab: Offene Sitzungen melden den Verlust, und das Gerät ist aus, bis man es wieder einschaltet.
    public func simulateConnectionLoss() {
        setSwitchedOn(false)
        let sessions = lock.withLock { liveSessions }
        for session in sessions { session.loseConnection() }
    }

    fileprivate func register(_ session: MockSession) { lock.withLock { liveSessions.append(session) } }
    fileprivate func unregister(_ session: MockSession) { lock.withLock { liveSessions.removeAll { $0 === session } } }

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
        let session = MockSession(owner: self, device: device, format: format, settings: settings)
        register(session)
        scheduleUnplugOnce()
        return session
    }

    /// Für den Testmodus der App: Beim ersten Öffnen wird das Gerät nach `after` Sekunden abgezogen und kommt
    /// `returnsAfter` Sekunden später wieder.
    private func scheduleUnplugOnce() {
        guard let plan = scheduledUnplug, lock.withLock({ () -> Bool in
            if unplugScheduled { return false }
            unplugScheduled = true
            return true
        }) else { return }
        Task {
            try? await Task.sleep(for: .seconds(plan.after))
            simulateConnectionLoss()
            try? await Task.sleep(for: .seconds(plan.returnsAfter))
            setSwitchedOn(true)
        }
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

/// Ein Merkmal, das einmal gesetzt wird und von mehreren Threads gelesen. Liegt vor `self`, damit die Vorschau-Task es
/// im Initialisierer schon benutzen kann.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    /// Gibt `true` zurück, wenn dieser Aufruf es gesetzt hat.
    func set() -> Bool { lock.withLock { let first = !value; value = true; return first } }
}

private final class MockSession: ScanSession, @unchecked Sendable {
    let device: DeviceInfo
    let format: ScanFormat
    let previewFrames: AsyncStream<PreviewFrame>
    let connectionLost: AsyncStream<ScannerError>

    private let lostContinuation: AsyncStream<ScannerError>.Continuation
    private let lost = OnceFlag()
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
        let (lostStream, lostContinuation) = AsyncStream<ScannerError>.makeStream()
        connectionLost = lostStream
        self.lostContinuation = lostContinuation
        let (stream, continuation) = AsyncStream<PreviewFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        previewFrames = stream
        let lost = self.lost
        previewTask = Task {
            var shade: CGFloat = 0
            while !Task.isCancelled {
                if owner.previewsEnabled, !lost.isSet, let image = Self.previewImage(shade: shade) { continuation.yield(PreviewFrame(image: image)) }
                // Eine stehende Vorschau ändert sich nie: wie ein ruhig liegendes Buch, die Auto-Auslösung sieht nur Ruhe.
                if !owner.stillPreview { shade = (shade + 0.1).truncatingRemainder(dividingBy: 1) }
                try? await Task.sleep(for: .milliseconds(30))
            }
            continuation.finish()
        }
    }

    /// Das Gerät ist weg: der Strom endet, eine Aufnahme scheitert, und der Verlust wird einmal gemeldet.
    func loseConnection() {
        guard !lock.withLock({ isClosed }), lost.set() else { return }
        lostContinuation.yield(.deviceNotFound)
        lostContinuation.finish()
    }

    func capture() async throws -> Capture {
        if let error = owner.captureError { throw error }
        guard !lock.withLock({ isClosed }), !lost.isSet else { throw ScannerError.deviceNotFound }
        // Eine Aufnahme, die dauert: der Verlust kann mitten hinein fallen.
        if owner.captureDelay > .zero { try? await Task.sleep(for: owner.captureDelay) }
        guard !lock.withLock({ isClosed }), !lost.isSet else { throw ScannerError.deviceNotFound }
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
        lostContinuation.finish()
        owner.unregister(self)
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
