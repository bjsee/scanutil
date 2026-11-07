import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Schlägt aus dem erkannten Text eines Dokuments eine kurze Beschreibung für den Dateinamen vor („Tierarztpraxis“).
public protocol DescriptionSuggesting: Sendable {
    /// Ob der Vorschlag auf diesem Rechner möglich ist.
    var isAvailable: Bool { get }
    /// Die Beschreibung oder `nil`, wenn keine zustande kam.
    func describe(text: String) async -> String?
}

/// Kein Vorschlag: die Vorgabe des Modells, damit Tests und der Betrieb ohne KI nichts nach außen tun.
public struct NoDescriber: DescriptionSuggesting {
    public init() {}
    public var isAvailable: Bool { false }
    public func describe(text: String) async -> String? { nil }
}

/// Die KI auf dem Mac (Apple Intelligence, Framework FoundationModels). Der Text bleibt auf dem Rechner.
public struct AppleIntelligenceDescriber: DescriptionSuggesting {
    public init() {}

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    public func describe(text: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard isAvailable else { return nil }
            let session = LanguageModelSession(instructions: """
                Du benennst eingescannte Dokumente eines Heimatvereins für den Dateinamen. Antworte mit höchstens vier Wörtern auf Deutsch, \
                die sagen, von wem das Dokument kommt oder was es ist, zum Beispiel „Tierarztpraxis Rechnung“, „Stadtwerke Jahresabrechnung“ \
                oder „Protokoll Vorstandssitzung“. Nur diese Wörter, keine Anführungszeichen, kein Satz, kein Datum.
                """)
            do {
                let response = try await session.respond(to: "Text des Dokuments:\n" + String(text.prefix(3000)))
                return response.content
            } catch { return nil }
        }
        #endif
        return nil
    }
}

extension UInt16 {
    /// `nil` für 0, sonst der Wert: für „nicht gesetzt“ in den gespeicherten Einstellungen.
    var nonZero: UInt16? { self == 0 ? nil : self }
}
