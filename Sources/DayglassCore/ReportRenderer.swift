import Foundation

public enum ReportFormat: String, CaseIterable, Sendable {
    case csv
    case json
    case md
    case otlpMetrics = "otlp-metrics"
}

public enum ReportTable: String, CaseIterable, Sendable {
    case time
    case ai
    case output
}

public enum ReportRenderer {
    public static func render(
        _ result: ReportResult,
        format: ReportFormat,
        table: ReportTable = .time,
        noTitles: Bool = false
    ) throws -> String {
        switch format {
        case .csv: return csv(result, table: table)
        case .json: return json(result, noTitles: noTitles)
        case .md: return markdown(result, noTitles: noTitles)
        case .otlpMetrics: return try metrics(result)
        }
    }

    private static func json(_ result: ReportResult, noTitles: Bool) -> String {
        let blocks = noTitles ? result.blocks.map {
            ReportBlock(
                start: $0.start,
                end: $0.end,
                project: $0.project,
                category: $0.category,
                projectBasis: $0.projectBasis,
                categoryBasis: $0.categoryBasis,
                confidence: $0.confidence,
                aiSeconds: $0.aiSeconds,
                title: nil
            )
        } : result.blocks
        let questions = noTitles ? result.questions.map { $0.withoutTitles() } : result.questions
        let value = ReportResult(time: result.time, ai: result.ai, output: result.output, blocks: blocks, questions: questions)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }

    private static func csv(_ result: ReportResult, table: ReportTable) -> String {
        switch table {
        case .time:
            var lines = ["day,project,category,seconds,ai_seconds,confidence,confirmed_seconds,inferred_seconds,unassigned_seconds,project_basis,category_basis"]
            lines += result.time.map { row in
                [row.day, row.project, row.category, String(row.seconds), String(row.aiSeconds), row.confidence, String(row.confirmedSeconds), String(row.inferredSeconds), String(row.unassignedSeconds), row.projectBasis, row.categoryBasis].map(csvField).joined(separator: ",")
            }
            return lines.joined(separator: "\n") + "\n"
        case .ai:
            var lines = ["day,project,agent,sessions,turns,edit_turns,input_uncached,cache_read,cache_write,output"]
            lines += result.ai.map { row in
                [row.day, row.project, row.agent, String(row.sessions), String(row.turns), String(row.editTurns), String(row.inputUncached), String(row.cacheRead), String(row.cacheWrite), String(row.output)].map(csvField).joined(separator: ",")
            }
            return lines.joined(separator: "\n") + "\n"
        case .output:
            var lines = ["day,project,commits,changed_lines,created_prs,merged_prs,reviewed_prs"]
            lines += result.output.map { row in
                [row.day, row.project, String(row.commits), String(row.changedLines), String(row.createdPRs), String(row.mergedPRs), String(row.reviewedPRs)].map(csvField).joined(separator: ",")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    private static func markdown(_ result: ReportResult, noTitles: Bool) -> String {
        var output = "# Dayglass report\n\n## Time\n\n"
        output += "| Day | Project | Category | Seconds | AI seconds | Confidence |\n| --- | --- | --- | ---: | ---: | --- |\n"
        output += result.time.map { "| \($0.day) | \($0.project ?? "") | \($0.category) | \($0.seconds) | \($0.aiSeconds) | \($0.confidence) |" }.joined(separator: "\n")
        output += "\n\n## AI\n\n| Day | Project | Agent | Sessions | Turns | Edits | Input uncached | Cache read | Cache write | Output |\n| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"
        output += result.ai.map { "| \($0.day) | \($0.project ?? "") | \($0.agent) | \($0.sessions) | \($0.turns) | \($0.editTurns) | \($0.inputUncached) | \($0.cacheRead) | \($0.cacheWrite) | \($0.output) |" }.joined(separator: "\n")
        output += "\n\n## Output\n\n| Day | Project | Commits | Changed lines | Created PRs | Merged PRs | Reviewed PRs |\n| --- | --- | ---: | ---: | ---: | ---: | ---: |\n"
        output += result.output.map { "| \($0.day) | \($0.project ?? "") | \($0.commits) | \($0.changedLines) | \($0.createdPRs) | \($0.mergedPRs) | \($0.reviewedPRs) |" }.joined(separator: "\n")
        output += "\n\n## Questions\n\n"
        output += result.questions.map { question in
            let evidence = noTitles ? "" : (question.evidence.isEmpty ? "" : " — \(question.evidence.joined(separator: ", "))")
            return "- `\(question.id)` \(question.kind) \(question.seconds)s [\(question.options.joined(separator: ", "))]\(evidence)"
        }.joined(separator: "\n")
        return output + "\n"
    }

    private static func metrics(_ result: ReportResult) throws -> String {
        let dataPoints = result.time.map { row in
            [
                "asDouble": Double(row.seconds),
                "attributes": [
                    ["key": "dayglass.project", "value": ["stringValue": row.project ?? ""]],
                    ["key": "dayglass.category", "value": ["stringValue": row.category]],
                    ["key": "dayglass.ai_assisted", "value": ["boolValue": row.aiSeconds > 0]],
                    ["key": "dayglass.confidence", "value": ["stringValue": row.confidence]],
                ],
            ] as [String: Any]
        }
        let object: [String: Any] = [
            "resourceMetrics": [[
                "resource": ["attributes": [["key": "service.name", "value": ["stringValue": "dayglass"]]]],
                "scopeMetrics": [["metrics": [["name": "dayglass.work.duration", "unit": "s", "gauge": ["dataPoints": dataPoints]]]]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

private func csvField(_ value: String?) -> String {
    guard let value else { return "" }
    guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
