public enum CLIHelp {
    public static let overview = """
    dayglass \(DayglassCore.version)

    Usage:
      dayglass <command> [options]
      dayglass help [command]

    Commands:
      report    Aggregate observed work and AI usage
      note      Record a correction or daily summary
      evidence  Build a redacted work excerpt
      pause     Temporarily pause observation
      sync      Fetch GitHub activity
      setup     Install hooks, telemetry, and launch agents
      daemon    Observe foreground applications
      serve     Receive local JSON OTLP/HTTP
      reap      Delete old observation logs
      version   Print the installed version

    Run 'dayglass help <command>' for command details.
    """

    public static func text(for command: String) -> String? {
        switch command {
        case "report":
            return """
            Usage:
              dayglass report [--month YYYY-MM] [--format FORMAT] [--table TABLE]
                              [--questions] [--freeze] [--no-titles]

            Aggregate local observations. GitHub synchronization is attempted first;
            local reporting continues if synchronization fails.

            Options:
              --month YYYY-MM   Month to report (default: current month)
              --format FORMAT   csv, json, md, or otlp-metrics (default: json)
              --table TABLE     time, ai, or output (default: time)
              --questions       Print unresolved time ranges as JSON
              --freeze          Save reproducible submission files
              --no-titles       Omit local window titles from JSON output
            """
        case "note":
            return """
            Usage:
              dayglass note --question ID --project CODE --category CATEGORY
              dayglass note --question ID --skip
              dayglass note --day YYYY-MM-DD --from HH:MM --to HH:MM [--project CODE]
                            [--category CATEGORY] [--skip]
              dayglass note --day YYYY-MM-DD --summary TEXT

            Record a human correction or confirmed daily summary. CATEGORY must be one of:
            research, coding, review, docs, meeting, or other.
            """
        case "evidence":
            return """
            Usage:
              dayglass evidence [--day YYYY-MM-DD] [--max-chars N]
                                [--codex-root PATH] [--claude-root PATH]

            Build a bounded, redacted excerpt from local agent transcripts.
            The default day is yesterday.
            """
        case "pause":
            return """
            Usage:
              dayglass pause DURATION
              dayglass pause --for DURATION

            Temporarily pause observation for a duration such as 15m, 2h, or 1d.
            """
        case "sync":
            return """
            Usage:
              dayglass sync github

            Fetch GitHub activity for configured projects using the authenticated gh CLI.
            """
        case "setup":
            return """
            Usage:
              dayglass setup [hooks|telemetry]

            With no argument, install hooks, telemetry settings, base files, the report
            skill, and launch agents. Specify 'hooks' or 'telemetry' to update only that component.
            """
        case "daemon":
            return """
            Usage:
              dayglass daemon

            Observe foreground applications and idle time. macOS Accessibility permission
            is required. Normally started by the launch agent installed by setup.
            """
        case "serve":
            return """
            Usage:
              dayglass serve

            Receive allowlisted JSON OTLP/HTTP on 127.0.0.1:4318.
            Normally started by the launch agent installed by setup.
            """
        case "reap":
            return """
            Usage:
              dayglass reap [--days N]

            Delete daily observation directories older than N days (default: 90).
            Frozen submissions are preserved.
            """
        case "hook":
            return """
            Usage:
              dayglass hook claude|codex < hook-payload.json

            Record agent lifecycle events. This command is normally called by installed hooks.
            """
        case "version":
            return """
            Usage:
              dayglass version
              dayglass --version

            Print the installed dayglass version.
            """
        default:
            return nil
        }
    }
}
