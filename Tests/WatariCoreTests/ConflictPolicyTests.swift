import Foundation
import Testing
import WatariCore

@Suite("ConflictPolicy")
struct ConflictPolicyTests {
    @Test("default is keepBoth")
    func defaultKeepBoth() {
        #expect(ConflictPolicy.default == .keepBoth)
    }

    @Test("keep both path allocation")
    func allocate() {
        let taken: Set<String> = ["report.pdf", "report 2.pdf"]
        #expect(KeepBothPath.allocate("report.pdf", taken: taken) == "report 3.pdf")
        #expect(KeepBothPath.allocate("readme", taken: ["readme"]) == "readme 2")
    }
}
