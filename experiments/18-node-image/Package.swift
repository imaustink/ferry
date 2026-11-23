// swift-tools-version:6.2
import PackageDescription

// Pinned to the same Containerization release ferry-cri uses, so the image
// store and the ext4 writer behave the same way in both.
let package = Package(
    name: "ferry-node",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.57.0")
    ],
    targets: [
        .executableTarget(
            name: "ferry-node",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
            ]
        ),
        // `swift test`, run by tests/run.sh.
        .testTarget(
            name: "ferry-node-tests",
            dependencies: ["ferry-node"]
        ),
    ],
    // Swift 5 mode: each VZVirtualMachine here is confined to its own serial
    // queue, which strict concurrency checking cannot see, so Swift 6 mode only
    // printed Sendable warnings on every build -- false alarms, and enough of
    // them to bury a real one.
    swiftLanguageModes: [.v5]
)
