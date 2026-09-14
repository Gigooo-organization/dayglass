// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    // Pure, side-effect-free logic: OTLP encoding, day files, time
    // accounting. Kept apart from the system-API shell so every rule here
    // is unit-testable without a Mac session.
    .target(name: "DayglassCore"),

    .testTarget(
        name: "DayglassCoreTests",
        dependencies: ["DayglassCore"]
    ),
]

// The single binary: daemon / hook / serve / report subcommands. It links
// AppKit / ApplicationServices and other macOS-only frameworks, so it is only
// built on macOS. On other hosts (e.g. Linux CI / Cloud Agents) the package
// still builds and tests the portable DayglassCore module.
#if os(macOS)
targets.append(
    .executableTarget(
        name: "dayglass",
        dependencies: ["DayglassCore"]
    )
)
#endif

let package = Package(
    name: "dayglass",
    platforms: [.macOS(.v13)],
    targets: targets
)
