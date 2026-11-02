import CoreGraphics
import Foundation

/// Scanner ohne Hardware für Tests und Entwicklung.
/// Liefert ein künstliches Testbild und merkt sich die Aufrufe.
public final class MockScanner: ScannerPort, @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public let format: ScanFormat
        public let settings: CaptureSettings
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private let formats: [ScanFormat]
    private let device: DeviceInfo
    private let failure: ScannerError?
    private let captureFailure: ScannerError?
    private let clock: @Sendable () -> Date

    public init(
        formats: [ScanFormat] = [ScanFormat(width: 640, height: 480), ScanFormat(width: 320, height: 240)],
        device: DeviceInfo = DeviceInfo(name: "Mock-Scanner", identifier: "mock"),
        failure: ScannerError? = nil,
        captureFailure: ScannerError? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.formats = formats
        self.device = device
        self.failure = failure
        self.captureFailure = captureFailure
        self.clock = clock
    }

    public var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    public func connect() async throws -> DeviceInfo {
        if let failure { throw failure }
        return device
    }

    public func availableFormats() async throws -> [ScanFormat] {
        if let failure { throw failure }
        return formats
    }

    public func previewFrames(format: ScanFormat) -> AsyncThrowingStream<PreviewFrame, Error> {
        AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            let task = Task {
                var shade: CGFloat = 0
                while !Task.isCancelled {
                    if let image = Self.previewImage(shade: shade) { continuation.yield(PreviewFrame(image: image)) }
                    shade = (shade + 0.1).truncatingRemainder(dividingBy: 1)
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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

    public func capture(format: ScanFormat, settings: CaptureSettings) async throws -> Capture {
        if let failure { throw failure }
        if let captureFailure { throw captureFailure }
        guard formats.contains(format) else { throw ScannerError.formatUnavailable(format) }
        lock.withLock { recordedCalls.append(Call(format: format, settings: settings)) }
        let data = try Self.testImage(width: format.width, height: format.height)
        return Capture(
            imageData: data, width: format.width, height: format.height,
            metadata: CaptureMetadata(device: device, requestedFormat: format, capturedAt: clock(), sharpness: settings.sharpness)
        )
    }

    private static func testImage(width: Int, height: Int) throws -> Data {
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
