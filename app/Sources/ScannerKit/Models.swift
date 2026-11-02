import CoreGraphics
import Foundation

/// Aufnahmeformat in Pixeln.
public struct ScanFormat: Codable, Hashable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }
    public var megapixels: Double { Double(width * height) / 1_000_000 }
}

/// Angaben zum verbundenen Gerät.
public struct DeviceInfo: Codable, Equatable, Sendable {
    public let name: String
    public let identifier: String

    public init(name: String, identifier: String) {
        self.name = name
        self.identifier = identifier
    }
}

/// Einstellungen für eine einzelne Aufnahme.
public struct CaptureSettings: Sendable, Equatable {
    /// Schärfe im Gerät (ET24 Pro: 0 bis 15). Für Archivscans 0, damit das Original unverfälscht bleibt.
    public var sharpness: Int?

    public init(sharpness: Int? = nil) {
        self.sharpness = sharpness
    }

    /// Voreinstellung für Archivaufnahmen.
    public static let archival = CaptureSettings(sharpness: 0)
}

/// Technische Angaben, die mit jeder Aufnahme gespeichert werden.
public struct CaptureMetadata: Codable, Equatable, Sendable {
    public let device: DeviceInfo
    public let requestedFormat: ScanFormat
    public let capturedAt: Date
    public let sharpness: Int?

    public init(device: DeviceInfo, requestedFormat: ScanFormat, capturedAt: Date, sharpness: Int?) {
        self.device = device
        self.requestedFormat = requestedFormat
        self.capturedAt = capturedAt
        self.sharpness = sharpness
    }
}

/// Ergebnis einer Aufnahme: verlustfrei kodierte Pixel (PNG) und ihre Herkunft.
public struct Capture: Sendable {
    public let imageData: Data
    public let width: Int
    public let height: Int
    public let metadata: CaptureMetadata

    public init(imageData: Data, width: Int, height: Int, metadata: CaptureMetadata) {
        self.imageData = imageData
        self.width = width
        self.height = height
        self.metadata = metadata
    }
}

/// Ein Bild der Live-Vorschau.
public struct PreviewFrame: @unchecked Sendable {
    public let image: CGImage

    public init(image: CGImage) {
        self.image = image
    }
}
