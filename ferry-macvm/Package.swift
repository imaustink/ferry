// swift-tools-version:6.2
import PackageDescription

// No dependencies: this needs Virtualization.framework and nothing else, the
// same reasoning ferry-gpud's Package.swift gives for Metal.
let package = Package(
    name: "ferry-macvm",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "ferry-macvm")
    ],
    // Swift 5 mode: everything here runs on one serial queue (vmQueue) and
    // Virtualization's callbacks, which strict concurrency checking cannot see,
    // so Swift 6 mode only printed two dozen Sendable warnings per build -- each
    // a false alarm, and enough of them to bury a real one.
    swiftLanguageModes: [.v5]
)
