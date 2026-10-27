import DayglassCore
import Testing

struct CodexConfigTests {
    @Test func detectsOTelInEveryTOMLShape() {
        #expect(codexConfigHasOTel("[otel]\nexporter = {}\n"))
        // Codex rewrites the inline tables into sub-tables on save.
        #expect(codexConfigHasOTel("model = \"o3\"\n\n[otel.exporter.otlp-http]\nendpoint = \"x\"\n"))
        #expect(codexConfigHasOTel("[ otel ] # comment\n"))
        #expect(codexConfigHasOTel("otel.exporter = \"none\"\n"))
        #expect(codexConfigHasOTel("otel = { exporter = \"none\" }\n"))
    }

    @Test func ignoresConfigWithoutOTel() {
        #expect(!codexConfigHasOTel(""))
        #expect(!codexConfigHasOTel("[otelx]\nhotel = 1\n# [otel]\n"))
    }
}
