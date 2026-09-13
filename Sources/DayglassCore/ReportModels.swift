import Foundation

public struct ObservedSpan: Equatable, Sendable {
    public let name: String
    public let start: Date
    public let end: Date
    public let attributes: [String: String]

    public init(name: String, start: Date, end: Date, attributes: [String: String] = [:]) {
        self.name = name
        self.start = start
        self.end = end
        self.attributes = attributes
    }
}

public struct ObservedLog: Equatable, Sendable {
    public let name: String
    public let timestamp: Date
    public let attributes: [String: String]

    public init(name: String, timestamp: Date, attributes: [String: String] = [:]) {
        self.name = name
        self.timestamp = timestamp
        self.attributes = attributes
    }
}

public struct ReportInput: Sendable {
    public let spans: [ObservedSpan]
    public let logs: [ObservedLog]

    public init(spans: [ObservedSpan] = [], logs: [ObservedLog] = []) {
        self.spans = spans
        self.logs = logs
    }
}

public struct ProjectRule: Equatable, Sendable {
    public let code: String
    public let name: String
    public let git: [String]
    public let title: [String]
    public let url: [String]

    public init(
        code: String,
        name: String = "",
        git: [String] = [],
        title: [String] = [],
        url: [String] = []
    ) {
        self.code = code
        self.name = name
        self.git = git
        self.title = title
        self.url = url
    }
}

public enum WorkCategory: String, CaseIterable, Codable, Sendable {
    case research
    case coding
    case review
    case docs
    case meeting
    case other
}

public struct CategoryRule: Equatable, Sendable {
    public let category: WorkCategory
    public let bundles: [String]
    public let domains: [String]
    public let paths: [String]

    public init(
        category: WorkCategory,
        bundles: [String] = [],
        domains: [String] = [],
        paths: [String] = []
    ) {
        self.category = category
        self.bundles = bundles
        self.domains = domains
        self.paths = paths
    }
}

public struct ReportThresholds: Equatable, Sendable {
    public var unassigned: TimeInterval
    public var ambiguousCategory: TimeInterval
    public var gap: TimeInterval
    public var missing: TimeInterval

    public init(
        unassigned: TimeInterval = 15 * 60,
        ambiguousCategory: TimeInterval = 30 * 60,
        gap: TimeInterval = 20 * 60,
        missing: TimeInterval = 20 * 60
    ) {
        self.unassigned = unassigned
        self.ambiguousCategory = ambiguousCategory
        self.gap = gap
        self.missing = missing
    }
}

public struct ReportConfiguration: Sendable {
    public var projects: [ProjectRule]
    public var categories: [CategoryRule]
    public var thresholds: ReportThresholds
    public var calendar: Calendar

    public init(
        projects: [ProjectRule] = [],
        categories: [CategoryRule] = [],
        thresholds: ReportThresholds = ReportThresholds(),
        calendar: Calendar = .current
    ) {
        self.projects = projects
        self.categories = categories
        self.thresholds = thresholds
        self.calendar = calendar
    }
}

public struct NoteRecord: Codable, Equatable, Sendable {
    public let start: Date?
    public let end: Date?
    public let project: String?
    public let category: String?
    public let summary: String?
    public let skip: Bool

    public init(
        start: Date? = nil,
        end: Date? = nil,
        project: String? = nil,
        category: String? = nil,
        summary: String? = nil,
        skip: Bool = false
    ) {
        self.start = start
        self.end = end
        self.project = project
        self.category = category
        self.summary = summary
        self.skip = skip
    }
}

public struct ReportTimeRow: Codable, Equatable, Sendable {
    public let day: String
    public let project: String?
    public let category: String
    public let seconds: Int
    public let aiSeconds: Int
    public let confidence: String
    public let confirmedSeconds: Int
    public let inferredSeconds: Int
    public let unassignedSeconds: Int
    public let projectBasis: String
    public let categoryBasis: String

    public init(
        day: String,
        project: String?,
        category: String,
        seconds: Int,
        aiSeconds: Int,
        confidence: String,
        confirmedSeconds: Int,
        inferredSeconds: Int,
        unassignedSeconds: Int,
        projectBasis: String,
        categoryBasis: String
    ) {
        self.day = day
        self.project = project
        self.category = category
        self.seconds = seconds
        self.aiSeconds = aiSeconds
        self.confidence = confidence
        self.confirmedSeconds = confirmedSeconds
        self.inferredSeconds = inferredSeconds
        self.unassignedSeconds = unassignedSeconds
        self.projectBasis = projectBasis
        self.categoryBasis = categoryBasis
    }
}

public struct ReportBlock: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let project: String?
    public let category: String
    public let projectBasis: String
    public let categoryBasis: String
    public let confidence: String
    public let aiSeconds: Int
    public let title: String?

    public init(
        start: Date,
        end: Date,
        project: String?,
        category: String,
        projectBasis: String,
        categoryBasis: String,
        confidence: String,
        aiSeconds: Int,
        title: String?
    ) {
        self.start = start
        self.end = end
        self.project = project
        self.category = category
        self.projectBasis = projectBasis
        self.categoryBasis = categoryBasis
        self.confidence = confidence
        self.aiSeconds = aiSeconds
        self.title = title
    }
}

public struct ReportAIRow: Codable, Equatable, Sendable {
    public let day: String
    public let project: String?
    public let agent: String
    public let sessions: Int
    public let turns: Int
    public let editTurns: Int
    public let inputUncached: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let output: Int

    public init(
        day: String,
        project: String?,
        agent: String,
        sessions: Int,
        turns: Int,
        editTurns: Int,
        inputUncached: Int,
        cacheRead: Int,
        cacheWrite: Int,
        output: Int
    ) {
        self.day = day
        self.project = project
        self.agent = agent
        self.sessions = sessions
        self.turns = turns
        self.editTurns = editTurns
        self.inputUncached = inputUncached
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
    }
}

public struct ReportOutputRow: Codable, Equatable, Sendable {
    public let day: String
    public let project: String?
    public let commits: Int
    public let changedLines: Int
    public let createdPRs: Int
    public let mergedPRs: Int
    public let reviewedPRs: Int

    public init(
        day: String,
        project: String?,
        commits: Int = 0,
        changedLines: Int = 0,
        createdPRs: Int = 0,
        mergedPRs: Int = 0,
        reviewedPRs: Int = 0
    ) {
        self.day = day
        self.project = project
        self.commits = commits
        self.changedLines = changedLines
        self.createdPRs = createdPRs
        self.mergedPRs = mergedPRs
        self.reviewedPRs = reviewedPRs
    }
}

public struct ReportQuestion: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let start: Date
    public let end: Date
    public let seconds: Int
    public let options: [String]
    public let evidence: [String]

    public init(
        id: String,
        kind: String,
        start: Date,
        end: Date,
        seconds: Int,
        options: [String],
        evidence: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.seconds = seconds
        self.options = options
        self.evidence = evidence
    }
}

public struct ReportResult: Codable, Equatable, Sendable {
    public let time: [ReportTimeRow]
    public let ai: [ReportAIRow]
    public let output: [ReportOutputRow]
    public let blocks: [ReportBlock]
    public let questions: [ReportQuestion]

    public init(
        time: [ReportTimeRow],
        ai: [ReportAIRow] = [],
        output: [ReportOutputRow] = [],
        blocks: [ReportBlock],
        questions: [ReportQuestion]
    ) {
        self.time = time
        self.ai = ai
        self.output = output
        self.blocks = blocks
        self.questions = questions
    }
}
