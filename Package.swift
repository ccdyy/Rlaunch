// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rlaunch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RlaunchCore", path: "Sources/RlaunchCore"),
        .executableTarget(name: "Rlaunch", dependencies: ["RlaunchCore"], path: "Sources/Rlaunch"),
        .executableTarget(name: "RlaunchSelfTest", dependencies: ["RlaunchCore"], path: "Sources/RlaunchSelfTest"),
    ]
)
