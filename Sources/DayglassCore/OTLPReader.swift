import Foundation

public extension OTLPJSONL {
    static func observedSpans(from data: Data) throws -> [ObservedSpan] {
        let object = try jsonObject(data)
        guard let resourceSpans = object["resourceSpans"] as? [[String: Any]] else { return [] }
        return resourceSpans.flatMap { resourceSpan in
            let resourceAttributes = attributes(from: resourceSpan["resource"])
            return (resourceSpan["scopeSpans"] as? [[String: Any]] ?? []).flatMap { scope in
                (scope["spans"] as? [[String: Any]] ?? []).compactMap { (span: [String: Any]) -> ObservedSpan? in
                    guard let name = span["name"] as? String,
                          let start = date(fromUnixNano: span["startTimeUnixNano"]),
                          let end = date(fromUnixNano: span["endTimeUnixNano"]),
                          end > start else { return nil }
                    var values = resourceAttributes
                    values.merge(attributes(from: span["attributes"])) { _, spanValue in spanValue }
                    return ObservedSpan(name: name, start: start, end: end, attributes: values)
                }
            }
        }
    }

    static func observedLogs(from data: Data) throws -> [ObservedLog] {
        let object = try jsonObject(data)
        guard let resourceLogs = object["resourceLogs"] as? [[String: Any]] else { return [] }
        return resourceLogs.flatMap { resourceLog in
            let resourceAttributes = attributes(from: resourceLog["resource"])
            return (resourceLog["scopeLogs"] as? [[String: Any]] ?? []).flatMap { scope in
                (scope["logRecords"] as? [[String: Any]] ?? []).compactMap { (record: [String: Any]) -> ObservedLog? in
                    guard let timestamp = date(fromUnixNano: record["timeUnixNano"] ?? record["observedTimeUnixNano"]) else { return nil }
                    var values = resourceAttributes
                    values.merge(attributes(from: record["attributes"])) { _, recordValue in recordValue }
                    let name = (record["eventName"] as? String) ?? (values["event.name"] ?? "log")
                    return ObservedLog(name: name, timestamp: timestamp, attributes: values)
                }
            }
        }
    }
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "DayglassCore.OTLP", code: 1, userInfo: [NSLocalizedDescriptionKey: "OTLP JSON root is not an object"])
    }
    return object
}

private func attributes(from raw: Any?) -> [String: String] {
    let rawAttributes: [[String: Any]]
    if let object = raw as? [String: Any], let nested = object["attributes"] as? [[String: Any]] {
        rawAttributes = nested
    } else if let direct = raw as? [[String: Any]] {
        rawAttributes = direct
    } else {
        return [:]
    }
    return rawAttributes.reduce(into: [String: String]()) { result, attribute in
        guard let key = attribute["key"] as? String,
              let value = attribute["value"] as? [String: Any] else { return }
        if let string = value["stringValue"] as? String {
            result[key] = string
        } else if let integer = value["intValue"] as? String {
            result[key] = integer
        } else if let number = value["intValue"] as? NSNumber {
            result[key] = number.stringValue
        } else if let boolean = value["boolValue"] as? Bool {
            result[key] = boolean ? "true" : "false"
        } else if let double = value["doubleValue"] as? NSNumber {
            result[key] = double.stringValue
        }
    }
}

private func date(fromUnixNano raw: Any?) -> Date? {
    let value: Double
    if let string = raw as? String, let parsed = Double(string) {
        value = parsed
    } else if let number = raw as? NSNumber {
        value = number.doubleValue
    } else {
        return nil
    }
    return Date(timeIntervalSince1970: value / 1_000_000_000)
}
