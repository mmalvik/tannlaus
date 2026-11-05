// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tannlaus",
    platforms: [.macOS(.v14)],
    targets: [
        // Sleep/wake logic with no AppKit dependency, so it can be unit-tested with a fake controller.
        .target(name: "TannlausCore"),
        // The menu bar app. The Makefile assembles it into Tannlaus.app.
        .executableTarget(name: "Tannlaus", dependencies: ["TannlausCore"]),
        .testTarget(name: "TannlausCoreTests", dependencies: ["TannlausCore"]),
    ]
)
