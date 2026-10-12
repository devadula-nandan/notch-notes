// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchNotes",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Terminal emulator for the terminal view
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.10.1"),
    ],
    targets: [
        // Text and storage logic with no UI, so it can be tested
        .target(
            name: "NotchNotesCore",
            path: "Sources/NotchNotesCore"
        ),
        .executableTarget(
            name: "NotchNotes",
            dependencies: ["NotchNotesCore", "SwiftTerm"],
            path: "Sources/NotchNotes",
            linkerSettings: [
                .linkedFramework("Cocoa")
            ]
        ),
        .testTarget(
            name: "NotchNotesCoreTests",
            dependencies: ["NotchNotesCore"],
            path: "Tests/NotchNotesCoreTests"
        ),
    ]
)
