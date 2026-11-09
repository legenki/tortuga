// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TortugaKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TortugaKit", targets: ["TortugaKit"])],
    targets: [
        .target(name: "TortugaKit"),
        .testTarget(name: "TortugaKitTests", dependencies: ["TortugaKit"]),
    ]
)
