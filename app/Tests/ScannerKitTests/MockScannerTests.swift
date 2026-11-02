import Testing
import Foundation
@testable import ScannerKit

@Suite("MockScanner")
struct MockScannerTests {
    @Test func connectReturnsDevice() async throws {
        let device = try await MockScanner().connect()
        #expect(device.name == "Mock-Scanner")
    }

    @Test func captureHasRequestedSizeAndRealPNG() async throws {
        let scanner = MockScanner()
        let format = ScanFormat(width: 320, height: 240)
        let capture = try await scanner.capture(format: format, settings: .archival)
        #expect(capture.width == 320)
        #expect(capture.height == 240)
        #expect(capture.imageData.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(capture.metadata.sharpness == 0)
    }

    @Test func recordsCalls() async throws {
        let scanner = MockScanner()
        _ = try await scanner.capture(format: ScanFormat(width: 640, height: 480), settings: CaptureSettings(sharpness: 3))
        #expect(scanner.calls.count == 1)
        #expect(scanner.calls[0].settings.sharpness == 3)
    }

    @Test func rejectsUnknownFormat() async {
        await #expect(throws: ScannerError.formatUnavailable(ScanFormat(width: 1, height: 1))) {
            _ = try await MockScanner().capture(format: ScanFormat(width: 1, height: 1), settings: .init())
        }
    }

    @Test func reportsConfiguredFailure() async {
        let scanner = MockScanner(failure: .deviceNotFound)
        await #expect(throws: ScannerError.deviceNotFound) { _ = try await scanner.connect() }
    }

    @Test func archivalSettingsUseSharpnessZero() {
        #expect(CaptureSettings.archival.sharpness == 0)
    }
}
