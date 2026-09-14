// swift-tools-version:6.2
import PackageDescription

// No dependencies, deliberately. Everything ferry-gpud needs -- Metal, MPS and
// the on-device model -- is in the OS, and the HTTP it speaks is small enough
// to own. A GPU daemon that has to fetch a package graph to start is a worse
// GPU daemon.
let package = Package(
    name: "ferry-gpud",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "ferry-gpud")
    ]
)
