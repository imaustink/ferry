// swift-tools-version:6.2
import PackageDescription

// Pinned to the Containerization release that vminit:0.57.0 is built from, so
// the host framework and the in-guest agent cannot drift. ferry-node
// (experiments/18-node-image) pins the same one.
//
// kernel/build-kernel.sh reads Apple's kernel configuration from its own
// CONTAINERIZATION_REF, still 0.45.0 on purpose: config-arm64 is identical up
// to 0.57.0, and that script is part of the kernel's recorded inputs, so moving
// the ref would rebuild the guest kernel for nothing.
let package = Package(
    name: "ferry-cri",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.57.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
        // 2.12.0 is the first release whose server config sets the HTTP/2
        // control-frame rate limit, which CRITransport.swift raises (experiment 38).
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.12.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.2.0"),
        // Already in the graph through Containerization and gRPC; named here only
        // so ferry-cri can own the one event loop group every pod VM shares.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.83.0"),
        // Also already in the graph; named so ferry-cri can hand FilePath to the
        // ext4 formatter when it formats a PersistentVolume's disk image.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "ferry-cri",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
            ]
        ),
        // Holds the node's vmnet network so its subnet outlives a ferry-cri
        // that dies; see Sources/ferry-netd/main.swift. vmnet and Foundation
        // only, so it starts in milliseconds and has nothing to crash with.
        .executableTarget(name: "ferry-netd"),
        // `swift test`, run by tests/run.sh. An executable target can be
        // imported @testable on macOS, so the tests reach the runtime's own
        // types without a library split.
        .testTarget(
            name: "ferry-cri-tests",
            dependencies: ["ferry-cri"]
        ),
    ]
)
