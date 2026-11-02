import CoreGraphics
import Foundation
import Vision

/// Eine erkannte Textzeile mit ihrem Platz auf der Seite.
public struct RecognizedLine: Equatable, Sendable {
    public let text: String
    /// Rahmen der Zeile, normiert auf die Seite (0 bis 1) mit Ursprung unten links wie im PDF.
    public let box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// Erkennt Text in einem Seitenbild. Eine Schnittstelle, damit die Erkennung austauschbar bleibt:
/// Vision ist eingebaut und schnell, für mehrspaltige Zeitungen und Fraktur kommt ein externes Werkzeug (ADR 0002) infrage.
public protocol TextRecognizer: Sendable {
    func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine]
}

/// Texterkennung mit Apple Vision. Misst im Spike rund 1,5 s je Seite bei deutschem Text (docs/spike-apple-vision.adoc).
public struct VisionTextRecognizer: TextRecognizer {
    public init() {}

    public func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return RecognizedLine(text: candidate.string, box: observation.boundingBox)
        }
    }
}
