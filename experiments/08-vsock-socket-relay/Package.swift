// swift-tools-version:6.2
import PackageDescription

// Pinned to the same release the vminit guest image comes from, so the host
// framework and the in-guest init cannot drift apart.
let package = Package(
    name: "relayprobe",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.45.0")
    ],
    targets: [
        .executableTarget(
            name: "relayprobe",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
            ]
        )
    ]
)
