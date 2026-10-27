import Foundation

/// Whether a Codex `config.toml` already defines the `otel` table in any
/// TOML shape. Codex rewrites the `[otel]` block it is given into
/// `[otel.exporter.otlp-http]` sub-tables on save, so matching only the
/// `[otel]` header made every re-run of setup append a duplicate key.
public func codexConfigHasOTel(_ contents: String) -> Bool {
    contents.range(of: #"(?m)^[ \t]*(\[[ \t]*otel[ \t]*[.\]]|otel[ \t]*[.=])"#, options: .regularExpression) != nil
}
