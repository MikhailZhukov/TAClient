import Testing
@testable import TAClient

struct DateFormattingTests {

    // MARK: - formatISO

    @Test func formatISO_nil_returnsEmpty() {
        #expect(DateFormatting.formatISO(nil) == "")
    }

    @Test func formatISO_fullISO8601WithFractionalSeconds() {
        let result = DateFormatting.formatISO("2024-01-15T10:30:00.000Z")
        #expect(!result.isEmpty)
        #expect(result != "2024-01-15T10:30:00.000Z") // Should be formatted, not raw
    }

    @Test func formatISO_iso8601WithoutFractionalSeconds() {
        let result = DateFormatting.formatISO("2024-01-15T10:30:00Z")
        #expect(!result.isEmpty)
        #expect(result != "2024-01-15T10:30:00Z")
    }

    @Test func formatISO_dateOnlyString() {
        let result = DateFormatting.formatISO("2024-01-15")
        #expect(!result.isEmpty)
        #expect(result != "2024-01-15") // Should be formatted
    }

    @Test func formatISO_invalidString_returnsOriginal() {
        #expect(DateFormatting.formatISO("not-a-date") == "not-a-date")
    }

    @Test func formatISO_usesNonBreakingSpaces() {
        let result = DateFormatting.formatISO("2024-01-15T10:30:00Z")
        // If the formatted date contains any space-like characters, they should be non-breaking
        #expect(!result.contains(" ")) // No regular spaces
        // The date may or may not contain non-breaking spaces depending on locale format,
        // but it should never contain regular spaces
    }

    // MARK: - formatUnixTimestamp

    @Test func formatUnixTimestamp_nil_returnsEmpty() {
        #expect(DateFormatting.formatUnixTimestamp(nil) == "")
    }

    @Test func formatUnixTimestamp_zero_returnsJan1970() {
        let result = DateFormatting.formatUnixTimestamp(0)
        #expect(!result.isEmpty)
        #expect(result.contains("1970"))
    }

    @Test func formatUnixTimestamp_knownDate() {
        // 2024-01-15 00:00:00 UTC = 1705276800
        let result = DateFormatting.formatUnixTimestamp(1705276800)
        #expect(!result.isEmpty)
        #expect(result.contains("2024"))
    }

    @Test func formatUnixTimestamp_usesNonBreakingSpaces() {
        let result = DateFormatting.formatUnixTimestamp(0)
        #expect(!result.contains(" ")) // No regular spaces
    }
}
