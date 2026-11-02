import AppKit
import ApplicationServices
import Foundation

/// Startet die echte App und bedient sie über die Bedienungshilfen (Accessibility API).
/// Voraussetzung: Das Programm, das die Tests startet, hat die Berechtigung „Bedienungshilfen“.
final class AppDriver {
    private var process: Process?
    private var launched: NSRunningApplication?
    let archive: URL
    private let application: AXUIElement

    /// Das Bundle aus `scripts/bundle.sh`. Es wird wie von einem Nutzer gestartet und darf sich in den Vordergrund holen.
    static func bundleURL(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/Scanutil.app")
    }

    init(mode: String, archive: URL) throws {
        self.archive = archive
        let environment = ["SCANUTIL_MOCK": mode, "SCANUTIL_ARCHIVE": archive.path]
        let bundle = Self.bundleURL()
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw DriverError.bundleMissing(bundle.path)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = environment
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        var result: Result<NSRunningApplication, Error>?
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
            if let app { result = .success(app) } else { result = .failure(error ?? DriverError.launchFailed) }
        }
        let end = Date().addingTimeInterval(20)
        while result == nil, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard let result else { throw DriverError.launchFailed }
        let app = try result.get()
        launched = app
        application = AXUIElementCreateApplication(app.processIdentifier)
    }

    enum DriverError: Error, CustomStringConvertible {
        case bundleMissing(String)
        case launchFailed
        var description: String {
            switch self {
            case .bundleMissing(let path): "Die App fehlt: \(path). Zuerst scripts/bundle.sh ausführen (oder scripts/ui-tests.sh)."
            case .launchFailed: "Die App ließ sich nicht starten."
            }
        }
    }

    var pid: pid_t { launched?.processIdentifier ?? 0 }
    var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

    func terminate() {
        launched?.forceTerminate()
        let end = Date().addingTimeInterval(5)
        while launched?.isTerminated == false, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// Wartet, bis die Bedingung gilt.
    @discardableResult
    func wait(timeout: Double = 20, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    // MARK: Elemente finden

    /// Gesucht wird nur im App-Fenster, nie in der Menüleiste (dort stehen zuletzt benutzte Dokumente).
    var root: AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first
    }

    func element(_ identifier: String) -> AXUIElement? { root.flatMap { find($0) { Self.string($0, kAXIdentifierAttribute) == identifier } } }
    func elements(_ identifier: String) -> [AXUIElement] { root.map { findAll($0) { Self.string($0, kAXIdentifierAttribute) == identifier } } ?? [] }

    func find(_ element: AXUIElement, depth: Int = 0, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(element) { return element }
        guard depth < 14 else { return nil }
        for child in Self.children(element) { if let hit = find(child, depth: depth + 1, where: match) { return hit } }
        return nil
    }

    func findAll(_ element: AXUIElement, depth: Int = 0, where match: (AXUIElement) -> Bool) -> [AXUIElement] {
        var result: [AXUIElement] = []
        if match(element) { result.append(element) }
        guard depth < 14 else { return result }
        for child in Self.children(element) { result += findAll(child, depth: depth + 1, where: match) }
        return result
    }

    // MARK: Aktionen

    @discardableResult
    func press(_ identifier: String) -> Bool {
        guard let el = element(identifier) else { return false }
        return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    /// Stellt einen Regler über seine Aktionen „Erhöhen“ und „Verringern“ ein, weil sein Wert nicht schreibbar ist.
    /// Gibt den erreichten Wert zurück.
    @discardableResult
    func adjust(_ identifier: String, to target: Double, tolerance: Double = 0.06, maxSteps: Int = 600) -> Double? {
        guard let el = element(identifier), var current = number(identifier) else { return nil }
        var steps = 0
        while abs(current - target) > tolerance, steps < maxSteps {
            let action = current < target ? kAXIncrementAction : kAXDecrementAction
            guard AXUIElementPerformAction(el, action as CFString) == .success else { break }
            guard let next = number(identifier) else { break }
            if next == current { break }
            current = next
            steps += 1
        }
        return current
    }

    /// Leertaste an genau diesen Prozess. Nur wenn die App vorn ist, sonst würde sie ins Leere gehen.
    /// Gibt `false` zurück, wenn die App nicht in den Vordergrund kam.
    func pressSpace() -> Bool {
        guard wait(timeout: 5, { isFrontmost }) else { return false }
        // Eine echte Ereignisquelle, sonst verwirft macOS synthetische Tastenereignisse unter Umständen.
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: down)
            event?.flags = []
            event?.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    // MARK: Lesen

    func string(_ identifier: String) -> String? { element(identifier).flatMap { Self.string($0, kAXValueAttribute) ?? Self.string($0, kAXTitleAttribute) } }
    func number(_ identifier: String) -> Double? {
        guard let el = element(identifier) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.doubleValue
    }
    /// Die erste Dezimalzahl in einem Text, zum Beispiel „+3,50°“ oder „+3.50°“.
    func numberInText(_ identifier: String) -> Double? {
        guard let text = string(identifier),
              let match = text.range(of: #"[+-]?\d+[.,]\d+"#, options: .regularExpression) else { return nil }
        return Double(text[match].replacingOccurrences(of: ",", with: "."))
    }

    func isEnabled(_ identifier: String) -> Bool? {
        guard let el = element(identifier) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
}
