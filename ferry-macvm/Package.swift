// swift-tools-version:6.2
import PackageDescription

// No dependencies: this needs Virtualization.framework and nothing else, the
// same reasoning ferry-gpud's Package.swift gives for Metal.
let package = Package(
    name: "ferry-macvm",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "ferry-macvm")
    ]
)
