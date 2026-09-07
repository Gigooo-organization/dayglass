// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dayglass",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure, side-effect-free logic: OTLP encoding, day files, time
        // accounting. Kept apart from the system-API shell so every rule here
        // is unit-testable without a Mac session.
        .target(name: "DayglassCore"),

        // The single binary: daemon / hook / serve / report subcommands.
        .executableTarget(
            name: "dayglass",
            dependencies: ["DayglassCore"]
        ),

        .testTarget(
            name: "DayglassCoreTests",
            dependencies: ["DayglassCore"]
        ),
    ]
)
