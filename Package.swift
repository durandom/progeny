// swift-tools-version: 6.1
import PackageDescription

// Slice 2: adds the OTLP transport via swift-otel. The libproc sampler stays
// dependency-free; only the emitter path pulls in the OTel/NIO stack.
let package = Package(
    name: "progenyd",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.4.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.4.1"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.4.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "progenyd",
            dependencies: [
                .product(name: "OTel", package: "swift-otel"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/progenyd"
        )
    ]
)
