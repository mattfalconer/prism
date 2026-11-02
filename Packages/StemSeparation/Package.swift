// swift-tools-version: 6.2
import PackageDescription

// On-device stem separation for Apple silicon: BS-Roformer on MLX, for whole files or a live stream.
let package = Package(
    name: "StemSeparation",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "StemSeparation", targets: ["StemSeparation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.32.3"),
    ],
    targets: [
        .target(name: "StemSeparation", dependencies: [.product(name: "MLX", package: "mlx-swift")]),
        .testTarget(name: "StemSeparationTests", dependencies: ["StemSeparation"]),
    ]
)
