import Testing
import Foundation
@testable import ScannerKit

@Suite("MockScanner")
struct MockScannerTests {
    private let small = ScanFormat(width: 320, height: 240)

    @Test func connectReturnsDevice() async throws {
        let device = try await MockScanner().connect()
        #expect(device.name == "Mock-Scanner")
    }

    @Test func captureHasRequestedSizeAndRealPNG() async throws {
        let session = try await MockScanner().openSession(format: small, settings: .archival)
        let capture = try await session.capture()
        await session.close()
        #expect(capture.width == 320)
        #expect(capture.height == 240)
        #expect(capture.imageData.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(capture.metadata.sharpness == 0)
    }

    @Test func recordsCallsAndSessions() async throws {
        let scanner = MockScanner()
        let session = try await scanner.openSession(format: ScanFormat(width: 640, height: 480), settings: CaptureSettings(sharpness: 3))
        _ = try await session.capture()
        _ = try await session.capture()
        #expect(scanner.openedSessions == 1)
        #expect(scanner.calls.count == 2)
        #expect(scanner.calls[0].settings.sharpness == 3)
        await session.close()
        #expect(scanner.closedSessions == 1)
    }

    @Test func closingTwiceIsHarmless() async throws {
        let scanner = MockScanner()
        let session = try await scanner.openSession(format: small, settings: .init())
        await session.close()
        await session.close()
        #expect(scanner.closedSessions == 1)
    }

    @Test func captureAfterCloseFails() async throws {
        let session = try await MockScanner().openSession(format: small, settings: .init())
        await session.close()
        await #expect(throws: ScannerError.deviceNotFound) { _ = try await session.capture() }
    }

    @Test func previewDeliversFrames() async throws {
        let session = try await MockScanner().openSession(format: small, settings: .init())
        var count = 0
        for await _ in session.previewFrames {
            count += 1
            if count == 3 { break }
        }
        await session.close()
        #expect(count == 3)
    }

    @Test func rejectsUnknownFormat() async {
        await #expect(throws: ScannerError.formatUnavailable(ScanFormat(width: 1, height: 1))) {
            _ = try await MockScanner().openSession(format: ScanFormat(width: 1, height: 1), settings: .init())
        }
    }

    @Test func reportsConfiguredFailure() async {
        let scanner = MockScanner(failure: .deviceNotFound)
        await #expect(throws: ScannerError.deviceNotFound) { _ = try await scanner.connect() }
        await #expect(throws: ScannerError.deviceNotFound) { _ = try await scanner.openSession(format: small, settings: .init()) }
    }

    @Test func archivalSettingsUseSharpnessZero() {
        #expect(CaptureSettings.archival.sharpness == 0)
    }
}
