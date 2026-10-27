import Foundation
import PackagePlugin

/// Generates `gitDescribe` for DayglassCore so a source build reports the commit it came from.
@main
struct GitDescribe: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let output = context.pluginWorkDirectoryURL.appending(path: "Generated", directoryHint: .isDirectory)
        // Only the package's own checkout counts: an unpacked tarball must not pick up an enclosing repository.
        // Rewrites the file only when the value changes, so unchanged builds do not recompile DayglassCore.
        let script = """
            mkdir -p "$2"
            d=$([ -e "$1/.git" ] && git -C "$1" --no-optional-locks describe --tags --always --dirty 2>/dev/null)
            if [ -n "$d" ]; then line="let gitDescribe: String? = \\"$d\\""; else line="let gitDescribe: String? = nil"; fi
            [ "$(cat "$2/GitDescribe.swift" 2>/dev/null)" = "$line" ] || printf '%s\\n' "$line" > "$2/GitDescribe.swift"
            """
        return [
            .prebuildCommand(
                displayName: "Describe git revision",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script, "sh", context.package.directoryURL.path, output.path],
                outputFilesDirectory: output
            ),
        ]
    }
}
