// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ProjKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ProjKitCore", targets: ["ProjKitCore"])],
    targets: [
        .target(name: "ProjKitCore"),
        // `swift run Checks` — test runner that works with the Command Line Tools alone
        // (Swift Testing/XCTest need full Xcode). `swift run Checks --mutate <root> <receipts>`
        // runs a scripted edit session against a copy of the projects tree for the
        // Python cross-check (see ios/README.md).
        .executableTarget(name: "Checks", dependencies: ["ProjKitCore"]),
    ]
)
