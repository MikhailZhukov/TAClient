import Testing
import Foundation
@testable import TAClient

struct MemoryDiagnosticsTests {

    /// Sanity-check the `mach_task_basic_info` plumbing — a running test
    /// process MUST have non-zero resident memory, and the formatted
    /// string MUST match the `\d+MB` shape the `[Mem]` log markers expect.
    @Test func residentBytes_returnsNonZeroValue() {
        let bytes = MemoryDiagnostics.residentBytes()
        #expect(bytes > 0)

        let formatted = MemoryDiagnostics.residentMBString()
        let regex = try? NSRegularExpression(pattern: #"^\d+MB$"#)
        let range = NSRange(formatted.startIndex..<formatted.endIndex, in: formatted)
        let match = regex?.firstMatch(in: formatted, range: range)
        #expect(match != nil, "residentMBString() returned \(formatted), expected to match ^\\d+MB$")
    }
}
