import Foundation

public extension ReportConfiguration {
    static func loadTOML(from url: URL, calendar: Calendar = DayglassCalendar.local) throws -> ReportConfiguration {
        let text = try String(contentsOf: url, encoding: .utf8)
        var projects: [ProjectRule] = []
        var categories: [CategoryRule] = []
        var section: String?
        var values: [String: String] = [:]

        func flush() {
            guard let section else { return }
            if section == "project", let rawCode = values["code"] {
                projects.append(ProjectRule(
                    code: scalar(rawCode),
                    name: scalar(values["name"]),
                    git: array(values["git"]),
                    title: array(values["title"]),
                    url: array(values["url"])
                ))
            } else if section == "category" {
                let rawCategory = scalar(values["category"] ?? values["name"])
                if let category = WorkCategory(rawValue: rawCategory) {
                    categories.append(CategoryRule(
                        category: category,
                        bundles: array(values["bundles"] ?? values["bundle"]),
                        domains: array(values["domains"] ?? values["domain"]),
                        paths: array(values["paths"] ?? values["path"])
                    ))
                }
            }
            values.removeAll(keepingCapacity: true)
        }

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = removeComment(String(line)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]" ) {
                flush()
                section = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            values[String(key)] = String(value)
        }
        flush()
        return ReportConfiguration(projects: projects, categories: categories, calendar: calendar)
    }
}

private func removeComment(_ line: String) -> String {
    var quoted = false
    for index in line.indices {
        if line[index] == "\"" { quoted.toggle() }
        if line[index] == "#" && !quoted { return String(line[..<index]) }
    }
    return line
}

private func scalar(_ value: String?) -> String {
    guard let value else { return "" }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") { return String(trimmed.dropFirst().dropLast()) }
    return trimmed
}

private func array(_ value: String?) -> [String] {
    guard let value else { return [] }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return [] }
    return trimmed.dropFirst().dropLast()
        .split(separator: ",", omittingEmptySubsequences: true)
        .map { scalar(String($0)) }
        .filter { !$0.isEmpty }
}
