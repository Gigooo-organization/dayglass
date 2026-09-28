import DayglassCore
import Testing

@Suite struct CLIHelpTests {
    @Test func listsCommandsAndDocumentsTheirOptions() throws {
        #expect(CLIHelp.overview.contains("dayglass help [command]"))
        #expect(CLIHelp.overview.contains("report    Aggregate observed work and AI usage"))

        let report = try #require(CLIHelp.text(for: "report"))
        #expect(report.contains("--format FORMAT"))
        #expect(report.contains("--questions"))
        #expect(report.contains("--days N"))
        #expect(report.contains("--suggest-rules"))
        let hook = try #require(CLIHelp.text(for: "hook"))
        #expect(hook.contains("additionalContext"))
        #expect(CLIHelp.text(for: "unknown") == nil)
    }
}
