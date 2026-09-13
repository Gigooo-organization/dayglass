import Foundation

public struct FilteredOTLP: Equatable, Sendable {
    public let data: Data?
    public let sourceService: String?
    public let keptRecords: Int
    public let droppedRecords: Int

    public init(data: Data?, sourceService: String?, keptRecords: Int, droppedRecords: Int) {
        self.data = data
        self.sourceService = sourceService
        self.keptRecords = keptRecords
        self.droppedRecords = droppedRecords
    }
}

public enum OTLPAllowlist {
    public static func filter(data: Data, signal: OTLPFileSignal) throws -> FilteredOTLP {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "DayglassCore.OTLP", code: 2, userInfo: [NSLocalizedDescriptionKey: "OTLP root is not an object"])
        }
        var kept = 0
        var dropped = 0
        var sourceService: String?
        switch signal {
        case .traces:
            let result = filterTraceResources(root["resourceSpans"] as? [[String: Any]] ?? [])
            root["resourceSpans"] = result.resources
            kept = result.kept
            dropped = result.dropped
            sourceService = result.service
        case .logs:
            let result = filterLogResources(root["resourceLogs"] as? [[String: Any]] ?? [])
            root["resourceLogs"] = result.resources
            kept = result.kept
            dropped = result.dropped
            sourceService = result.service
        case .metrics:
            let result = filterMetricResources(root["resourceMetrics"] as? [[String: Any]] ?? [])
            root["resourceMetrics"] = result.resources
            kept = result.kept
            dropped = result.dropped
            sourceService = result.service
        }
        let output = kept == 0 ? nil : try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return FilteredOTLP(data: output, sourceService: sourceService, keptRecords: kept, droppedRecords: dropped)
    }
}

private func filterTraceResources(_ resources: [[String: Any]]) -> (resources: [[String: Any]], service: String?, kept: Int, dropped: Int) {
    var output: [[String: Any]] = []
    var service: String?
    var kept = 0
    var dropped = 0
    for resource in resources {
        var copy = resource
        service = service ?? resourceService(resource["resource"])
        copy["resource"] = filteredResource(resource["resource"])
        var scopes: [[String: Any]] = []
        for scope in resource["scopeSpans"] as? [[String: Any]] ?? [] {
            var scopeCopy = scope
            let spans = (scope["spans"] as? [[String: Any]] ?? []).compactMap { span -> [String: Any]? in
                guard let name = span["name"] as? String, allowedTrace(name) else { dropped += 1; return nil }
                kept += 1
                var spanCopy = span
                spanCopy["attributes"] = filteredAttributes(span["attributes"], allowed: allowedTraceAttribute)
                return spanCopy
            }
            if !spans.isEmpty { scopeCopy["spans"] = spans; scopes.append(scopeCopy) }
        }
        if !scopes.isEmpty { copy["scopeSpans"] = scopes; output.append(copy) }
    }
    return (output, service, kept, dropped)
}

private func filterLogResources(_ resources: [[String: Any]]) -> (resources: [[String: Any]], service: String?, kept: Int, dropped: Int) {
    var output: [[String: Any]] = []
    var service: String?
    var kept = 0
    var dropped = 0
    for resource in resources {
        var copy = resource
        service = service ?? resourceService(resource["resource"])
        copy["resource"] = filteredResource(resource["resource"])
        var scopes: [[String: Any]] = []
        for scope in resource["scopeLogs"] as? [[String: Any]] ?? [] {
            var scopeCopy = scope
            let records = (scope["logRecords"] as? [[String: Any]] ?? []).compactMap { record -> [String: Any]? in
                let eventName = record["eventName"] as? String ?? attributeString(record["attributes"], key: "event.name") ?? ""
                guard allowedLog(eventName, attributes: record["attributes"]) else { dropped += 1; return nil }
                kept += 1
                var recordCopy = record
                recordCopy["attributes"] = filteredAttributes(record["attributes"], allowed: allowedLogAttribute)
                return recordCopy
            }
            if !records.isEmpty { scopeCopy["logRecords"] = records; scopes.append(scopeCopy) }
        }
        if !scopes.isEmpty { copy["scopeLogs"] = scopes; output.append(copy) }
    }
    return (output, service, kept, dropped)
}

private func filterMetricResources(_ resources: [[String: Any]]) -> (resources: [[String: Any]], service: String?, kept: Int, dropped: Int) {
    var output: [[String: Any]] = []
    var service: String?
    var kept = 0
    var dropped = 0
    for resource in resources {
        var copy = resource
        service = service ?? resourceService(resource["resource"])
        copy["resource"] = filteredResource(resource["resource"])
        var scopes: [[String: Any]] = []
        for scope in resource["scopeMetrics"] as? [[String: Any]] ?? [] {
            var scopeCopy = scope
            let metrics = (scope["metrics"] as? [[String: Any]] ?? []).compactMap { metric -> [String: Any]? in
                guard let name = metric["name"] as? String, allowedMetric(name) else { dropped += 1; return nil }
                kept += 1
                var metricCopy = metric
                for key in ["gauge", "sum", "histogram"] {
                    if var body = metric[key] as? [String: Any] {
                        body["dataPoints"] = (body["dataPoints"] as? [[String: Any]] ?? []).map { point in
                            var pointCopy = point
                            pointCopy["attributes"] = filteredAttributes(point["attributes"], allowed: allowedMetricAttribute)
                            return pointCopy
                        }
                        metricCopy[key] = body
                    }
                }
                return metricCopy
            }
            if !metrics.isEmpty { scopeCopy["metrics"] = metrics; scopes.append(scopeCopy) }
        }
        if !scopes.isEmpty { copy["scopeMetrics"] = scopes; output.append(copy) }
    }
    return (output, service, kept, dropped)
}

private func resourceService(_ raw: Any?) -> String? {
    attributeString((raw as? [String: Any])?["attributes"], key: "service.name")
}

private func filteredResource(_ raw: Any?) -> [String: Any] {
    guard var resource = raw as? [String: Any] else { return [:] }
    resource["attributes"] = filteredAttributes(resource["attributes"]) { $0 == "service.name" }
    return resource
}

private func filteredAttributes(_ raw: Any?, allowed: (String) -> Bool) -> [[String: Any]] {
    (raw as? [[String: Any]] ?? []).filter { attribute in
        guard let key = attribute["key"] as? String else { return false }
        return allowed(key)
    }
}

private func attributeString(_ raw: Any?, key: String) -> String? {
    for attribute in raw as? [[String: Any]] ?? [] where attribute["key"] as? String == key {
        let value = attribute["value"] as? [String: Any]
        return value?["stringValue"] as? String ?? (value?["intValue"] as? String)
    }
    return nil
}

private func allowedTrace(_ name: String) -> Bool { name == "session_task.turn" || name == "gen_ai.session" || name == "gen_ai.turn" }
private func allowedTraceAttribute(_ key: String) -> Bool {
    ["turn.id", "conversation.id", "gen_ai.agent.name", "gen_ai.request.model", "vcs.repository.url.full", "dayglass.cwd"].contains(key) || key.hasPrefix("codex.turn.token_usage.")
}
private func allowedLog(_ name: String, attributes: Any?) -> Bool {
    if name == "api_request" { return true }
    if name == "codex.sse_event" { return attributeString(attributes, key: "event.kind") == "response.completed" }
    return false
}
private func allowedLogAttribute(_ key: String) -> Bool {
    ["session.id", "model", "input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens", "duration_ms", "conversation.id", "turn.id"].contains(key) || key.hasSuffix("_token_count")
}
private func allowedMetric(_ name: String) -> Bool { ["claude_code.token.usage", "claude_code.active_time.total", "codex.turn.token_usage"].contains(name) }
private func allowedMetricAttribute(_ key: String) -> Bool { ["type", "model", "session.id", "token_type"].contains(key) }
