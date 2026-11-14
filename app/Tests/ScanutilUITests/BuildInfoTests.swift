import Foundation
import Testing
@testable import ScanutilUI

@Suite("Version in der Oberfläche")
struct BuildInfoTests {
    @Test func theTimestampIsShownAsGermanDateAndTimeWithoutSeconds() {
        #expect(BuildInfo.display("2026-11-14 09:41:07") == "Version 14.11.2026 09:41")
        #expect(BuildInfo.display("2027-01-02 00:05:59") == "Version 02.01.2027 00:05", "Führende Nullen bleiben")
        #expect(BuildInfo.display("2026-12-31 23:59:59") == "Version 31.12.2026 23:59")
    }

    @Test func withoutATimestampItIsADevelopmentBuildAndAnUnknownFormatIsShownAsIs() {
        #expect(BuildInfo.display(nil) == "Entwicklungsstand")
        #expect(BuildInfo.display("") == "Entwicklungsstand")
        #expect(BuildInfo.display("gestern abend") == "Version gestern abend", "Nichts verschweigen, was nicht passt")
    }

    @Test func aBundleWithoutTheKeysGivesNoTimestampAndNoCommit() {
        // Das Testbündel ist nicht von bundle.sh gebaut.
        #expect(BuildInfo.timestamp(bundle: Bundle(for: BundleToken.self)) == nil)
        #expect(BuildInfo.commit(bundle: Bundle(for: BundleToken.self)) == nil)
    }

    private final class BundleToken {}
}
