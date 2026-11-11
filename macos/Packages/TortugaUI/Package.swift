// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TortugaUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TortugaUI", targets: ["TortugaUI"])],
    dependencies: [.package(path: "../TortugaKit")],
    targets: [
        .target(name: "TortugaUI", dependencies: ["TortugaKit"]),
        .testTarget(name: "TortugaUIPackageTests", dependencies: ["TortugaUI", "TortugaKit"]),
    ]
)
