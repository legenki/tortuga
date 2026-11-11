// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TortugaProxyKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TortugaProxyKit", targets: ["TortugaProxyKit"])],
    dependencies: [.package(path: "../TortugaKit")],
    targets: [
        .target(name: "TortugaProxyKit", dependencies: ["TortugaKit"]),
        .testTarget(name: "TortugaProxyKitTests", dependencies: ["TortugaProxyKit", "TortugaKit"]),
    ]
)
