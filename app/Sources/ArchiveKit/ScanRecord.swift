import Foundation
import ScannerKit

/// Dauerhafter Eintrag zu einem gespeicherten Original. Wird als JSON neben dem Original abgelegt.
public struct ScanRecord: Codable, Equatable, Sendable, Identifiable {
    public struct OriginalFile: Codable, Equatable, Sendable {
        /// Pfad relativ zum Archivstamm.
        public let path: String
        /// SHA-256 der Originaldatei, kleingeschrieben hexadezimal.
        public let sha256: String
        public let bytes: Int
        public let width: Int
        public let height: Int
    }

    public let id: UUID
    public let storedAt: Date
    public let original: OriginalFile
    public let capture: CaptureMetadata
}
