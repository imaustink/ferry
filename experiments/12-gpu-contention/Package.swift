// swift-tools-version:6.2
import PackageDescription

// No dependencies: Metal, MPS and the on-device model are all in the OS, which
// is the whole point -- this measures what the machine does, not what a stack
// on top of it does.
let package = Package(
    name: "contention",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "contention")
    ]
)
