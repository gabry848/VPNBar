// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VPNBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VPNBar", targets: ["VPNBar"]),
        .executable(name: "VPNBarCLI", targets: ["VPNBarCLI"]),
        .executable(name: "VPNBarNetwork", targets: ["VPNBarNetwork"]),
        .executable(name: "VPNBarShareAgent", targets: ["VPNBarShareAgent"])
    ],
    targets: [
        .target(name: "VPNBarCore"),
        .executableTarget(name: "VPNBar", dependencies: ["VPNBarCore"]),
        .executableTarget(name: "VPNBarCLI", dependencies: ["VPNBarCore"]),
        .executableTarget(name: "VPNBarNetwork", dependencies: ["VPNBarCore"]),
        .executableTarget(name: "VPNBarShareAgent"),
        .testTarget(name: "VPNBarCoreTests", dependencies: ["VPNBarCore"])
    ]
)
