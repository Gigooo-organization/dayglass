import Foundation

public enum OTLPValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)

    private enum CodingKeys: String, CodingKey {
        case stringValue
        case intValue
        case doubleValue
        case boolValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value): try container.encode(value, forKey: .stringValue)
        case .int(let value): try container.encode(String(value), forKey: .intValue)
        case .double(let value): try container.encode(value, forKey: .doubleValue)
        case .bool(let value): try container.encode(value, forKey: .boolValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .stringValue) {
            self = .string(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .intValue),
                  let integer = Int64(value) {
            self = .int(integer)
        } else if let value = try container.decodeIfPresent(Int64.self, forKey: .intValue) {
            self = .int(value)
        } else if let value = try container.decodeIfPresent(Double.self, forKey: .doubleValue) {
            self = .double(value)
        } else if let value = try container.decodeIfPresent(Bool.self, forKey: .boolValue) {
            self = .bool(value)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .stringValue,
                in: container,
                debugDescription: "unsupported OTLP anyValue"
            )
        }
    }
}

public struct OTLPAttribute: Codable, Equatable, Sendable {
    public let key: String
    public let value: OTLPValue

    public init(key: String, value: OTLPValue) {
        self.key = key
        self.value = value
    }
}

public struct OTLPResource: Codable, Equatable, Sendable {
    public let attributes: [OTLPAttribute]

    public init(attributes: [OTLPAttribute] = []) {
        self.attributes = attributes
    }
}

public struct OTLPSpan: Codable, Equatable, Sendable {
    public let name: String
    public let startTimeUnixNano: String
    public let endTimeUnixNano: String
    public let attributes: [OTLPAttribute]

    public init(
        name: String,
        startTimeUnixNano: String,
        endTimeUnixNano: String,
        attributes: [OTLPAttribute] = []
    ) {
        self.name = name
        self.startTimeUnixNano = startTimeUnixNano
        self.endTimeUnixNano = endTimeUnixNano
        self.attributes = attributes
    }
}

private struct OTLPScopeSpans: Codable, Equatable, Sendable {
    let spans: [OTLPSpan]
}

private struct OTLPResourceSpans: Codable, Equatable, Sendable {
    let resource: OTLPResource
    let scopeSpans: [OTLPScopeSpans]
}

private struct OTLPTraceExport: Codable, Equatable, Sendable {
    let resourceSpans: [OTLPResourceSpans]
}

public enum OTLPJSONL {
    public static func traceLine(
        span: OTLPSpan,
        resource: OTLPResource = OTLPResource()
    ) throws -> String {
        let value = OTLPTraceExport(
            resourceSpans: [OTLPResourceSpans(resource: resource, scopeSpans: [OTLPScopeSpans(spans: [span])])]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
