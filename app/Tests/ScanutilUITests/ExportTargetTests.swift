import Foundation
import Testing
@testable import ScanutilUI

@Suite("PDF-Ziel")
struct ExportTargetTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanutil-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func theFileNameKeepsTheTitleAndAddsPdfOnce() {
        #expect(ExportTarget.fileName(for: "Chronik 1524") == "Chronik 1524.pdf")
        #expect(ExportTarget.fileName(for: "Chronik.pdf") == "Chronik.pdf")
        #expect(ExportTarget.fileName(for: "Chronik.PDF") == "Chronik.pdf")
    }

    @Test func slashesAndColonsDoNotEndUpInTheName() {
        #expect(ExportTarget.fileName(for: "Serie 03.11.2026, 20:09") == "Serie 03.11.2026, 20.09.pdf")
        #expect(ExportTarget.fileName(for: "a/b") == "a-b.pdf")
    }

    @Test func anEmptyOrHiddenNameBecomesSerie() {
        #expect(ExportTarget.fileName(for: "   ") == "Serie.pdf")
        #expect(ExportTarget.fileName(for: "") == "Serie.pdf")
        #expect(ExportTarget.fileName(for: "..versteckt") == "versteckt.pdf")
        #expect(ExportTarget.fileName(for: ".pdf") == "Serie.pdf")
    }

    @Test func anExistingFileIsNeverOverwritten() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = ExportTarget.url(directory: dir, title: "Chronik")
        #expect(first.lastPathComponent == "Chronik.pdf")
        try Data().write(to: first)
        let second = ExportTarget.url(directory: dir, title: "Chronik")
        #expect(second.lastPathComponent == "Chronik 2.pdf")
        try Data().write(to: second)
        #expect(ExportTarget.url(directory: dir, title: "Chronik").lastPathComponent == "Chronik 3.pdf")
        #expect(ExportTarget.url(directory: dir, title: "Chronik.pdf").lastPathComponent == "Chronik 3.pdf", "Auch mit Endung")
    }

    @Test func theDefaultFolderIsDocumentsScanutilUnlessTheEnvironmentSaysOtherwise() {
        #expect(ExportTarget.defaultDirectory(environment: [:]).path.hasSuffix("/Documents/Scanutil"))
        #expect(ExportTarget.defaultDirectory(environment: ["SCANUTIL_EXPORT_DIR": "/tmp/x"]).path == "/tmp/x")
    }
}
