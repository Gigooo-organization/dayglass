public enum DayglassCore {
    public static let version = resolveVersion(release: releaseVersion, gitDescribe: gitDescribe)
    static let releaseVersion = "0.6.1"
}

/// `gitDescribe` is generated at build time by the GitDescribe plugin. It is nil for builds
/// without a git checkout, such as the Homebrew source tarball.
func resolveVersion(release: String, gitDescribe: String?) -> String {
    guard let gitDescribe else { return release }
    guard gitDescribe.hasPrefix("v") else { return "\(release)+\(gitDescribe)" }
    return String(gitDescribe.dropFirst())
}
