// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OcPlayerCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "OcPlayerCore", targets: ["OcPlayerCore"])],
    targets: [.target(name: "OcPlayerCore")]
)
