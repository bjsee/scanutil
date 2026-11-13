import Foundation
import ImagingKit

/// Ein Befund zu einer Seite: Wo die Automatik unsicher war oder etwas Beachtenswertes tat.
public struct Finding: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// Seitenrand nicht erkannt oder unsicher.
        case outer
        /// Falz einer Doppelseite nicht gefunden oder unsicher.
        case gutter
        /// Zuschnitt unsicher oder nicht angewendet, ohne dass sich Rand und Falz trennen ließen (ältere Dokumente).
        case crop
        case rotation
        case hands
        /// Vom Nutzer geändert.
        case manual
        /// Noch nicht analysiert.
        case pending
    }

    /// Wie schwer: ein *Hinweis* ist nur eine Information, *Prüfen* und *Problem* zählen als unsicher.
    public enum Severity: Int, Comparable, Sendable {
        case note = 0, check = 1, problem = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public let kind: Kind
    public let severity: Severity
    public let message: String
    public var id: String { kind.rawValue + "|" + message }
}

/// Die Bewertung einer Seite: ihre Befunde und ob sie Aufmerksamkeit braucht.
public struct PageReview: Equatable, Sendable {
    public let findings: [Finding]
    public let isReviewed: Bool

    /// Die schwerste Stufe, oder `nil` ohne Befund.
    public var severity: Finding.Severity? { findings.map(\.severity).max() }

    /// Ob die Automatik bei der Seite unsicher war: mindestens ein Befund der Stufe *Prüfen* oder *Problem*.
    public var isUncertain: Bool { (severity ?? .note) >= .check }

    /// Ob die Seite noch angesehen werden sollte: unsicher und vom Nutzer noch nicht als geprüft markiert.
    public var needsAttention: Bool { isUncertain && !isReviewed }

    public func has(_ kinds: Set<Finding.Kind>) -> Bool { findings.contains { kinds.contains($0.kind) } }
}

public enum PageReviewer {
    /// Unterhalb dieser Sicherheit gilt eine Erkennung als unsicher, wie in den Korrekturen.
    public static let defaultThreshold = Corrections.defaultConfidenceThreshold

    /// Bewertet eine Seite aus ihren Korrekturen und, falls vorhanden, ihrer Analyse-Zusammenfassung. Ältere Dokumente haben keine
    /// Zusammenfassung: Dann gilt, was sich aus den Korrekturen ablesen lässt (die Sicherheit des Zuschnitts, der Drehung).
    public static func review(_ page: DocumentPage, threshold: Double = defaultThreshold) -> PageReview {
        let c = page.corrections
        let isBook = page.region != .whole
        var findings: [Finding] = []
        func add(_ kind: Finding.Kind, _ severity: Finding.Severity, _ message: String) {
            findings.append(Finding(kind: kind, severity: severity, message: message))
        }
        func fmt(_ value: Double) -> String { String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",") }

        // Noch nie analysiert: nichts davon lässt sich beurteilen.
        let neverAnalyzed = page.analysis == nil && c.crop.quad == nil && c.rotation.confidence == nil && !c.handRemoval.hasMask
            && c.crop.source == .automatic && c.rotation.source == .automatic
        if neverAnalyzed {
            add(.pending, .check, "Noch nicht analysiert.")
        } else {
            // Zuschnitt: Rand und Falz getrennt, wenn die Zusammenfassung da ist, sonst über die Sicherheit des Zuschnitts.
            if let a = page.analysis {
                if !a.outerDetected {
                    add(.outer, .problem, a.isSpread ? "Der Rand des Buchs wurde nicht erkannt: Die Seite enthält Tuch."
                                                     : "Der Rand der Seite wurde nicht erkannt.")
                } else if let p = a.outerPlausibility, p < threshold {
                    add(.outer, .check, "Seitenrand unsicher (\(fmt(p)))" + notApplied(c, isBook: isBook))
                }
                if isBook {
                    if let g = a.gutterConfidence {
                        if g < threshold { add(.gutter, .check, "Falz unsicher (\(fmt(g)))") }
                    } else {
                        add(.gutter, .problem, "Der Falz wurde nicht gefunden: In der Mitte geteilt.")
                    }
                }
            } else if c.crop.source == .automatic {
                if c.crop.quad == nil {
                    add(.crop, .problem, "Kein Zuschnitt erkannt.")
                } else if let confidence = c.crop.confidence, confidence < threshold {
                    add(.crop, .check, (isBook ? "Zuschnitt oder Falz unsicher" : "Zuschnitt unsicher") + " (\(fmt(confidence)))" + notApplied(c, isBook: isBook))
                }
            }

            // Drehung: nur eine automatische, nicht angewendete Messung ist ein Befund.
            if c.rotation.source == .automatic, !c.rotation.enabled {
                if let confidence = c.rotation.confidence {
                    if confidence < 0.05 {
                        add(.rotation, .note, "Drehung nicht messbar (kaum Text auf der Seite).")
                    } else if confidence < threshold, abs(c.rotation.degrees) >= 0.3 {
                        add(.rotation, .check, "Drehung unsicher (\(String(format: "%+.1f", c.rotation.degrees).replacingOccurrences(of: ".", with: ","))°, nicht angewendet)")
                    }
                }
            }

            // Wölbung: nur ein Hinweis, damit man sieht, wo die Seite verformt wurde.
            if let field = c.dewarp.field {
                let span = String(format: "%.1f", field.spread).replacingOccurrences(of: ".", with: ",")
                if c.dewarp.enabled {
                    add(.rotation, .note, "Wölbung ausgeglichen (Zeilen liefen um \(span)° auseinander).")
                } else if c.dewarp.source == .automatic, field.isWorthEqualizing {
                    add(.rotation, .note, "Wölbung gemessen (\(span)°), aber nicht ausgeglichen.")
                }
            }

            // Hände und Marker.
            if c.handRemoval.hasMask {
                let share = page.analysis?.handCoverage.map { " (\(Int(($0 * 100).rounded())) % des Bildes)" } ?? ""
                if c.handRemoval.enabled {
                    add(.hands, .note, "Hände oder Daumen entfernt" + share + ". Am Rand prüfen, ob Text fehlt.")
                } else if c.handRemoval.source == .automatic {
                    add(.hands, .check, "Hände erkannt, aber nicht entfernt (zu unsicher)" + share + ".")
                } else {
                    add(.hands, .note, "Hände erkannt, Entfernen von Hand ausgeschaltet.")
                }
            }
        }

        // Von Hand geändert.
        var manual: [String] = []
        if c.crop.source == .manual { manual.append("Zuschnitt") }
        if c.rotation.source == .manual { manual.append("Drehung") }
        if c.handRemoval.source == .manual && c.handRemoval.hasMask { manual.append("Hände") }
        if c.dewarp.source == .manual && c.dewarp.hasField { manual.append("Wölbung") }
        if !manual.isEmpty { add(.manual, .note, "Von Hand geändert: " + manual.joined(separator: ", ") + ".") }

        return PageReview(findings: findings, isReviewed: page.isReviewed)
    }

    /// „, nicht angewendet“, wenn ein unsicherer Zuschnitt nicht wirkt. Bei Buchseiten wirkt er immer (siehe `PageGeometry`).
    private static func notApplied(_ c: Corrections, isBook: Bool) -> String {
        (!isBook && !c.crop.enabled && c.crop.quad != nil) ? ", nicht angewendet" : ""
    }
}

/// Die Bewertung aller Seiten eines Dokuments.
public struct DocumentReview: Equatable, Sendable {
    public let pages: [UUID: PageReview]
    public let order: [UUID]

    public init(_ document: ScanDocument, threshold: Double = PageReviewer.defaultThreshold) {
        var map: [UUID: PageReview] = [:]
        for page in document.pages { map[page.id] = PageReviewer.review(page, threshold: threshold) }
        pages = map
        order = document.pages.map(\.id)
    }

    public func review(of pageID: UUID) -> PageReview? { pages[pageID] }
    /// Seiten, die noch angesehen werden sollten.
    public var needingAttention: [UUID] { order.filter { pages[$0]?.needsAttention == true } }
    public var uncertainCount: Int { order.filter { pages[$0]?.isUncertain == true }.count }
    public var reviewedCount: Int { order.filter { pages[$0]?.isReviewed == true }.count }
}
