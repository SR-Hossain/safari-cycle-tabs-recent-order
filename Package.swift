// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SafariRecentTabs",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SafariRecentTabs", targets: ["SafariRecentTabsApp"])
    ],
    targets: [
        .target(name: "SafariRecentTabsCore"),
        .executableTarget(
            name: "SafariRecentTabsApp",
            dependencies: ["SafariRecentTabsCore"]
        )
    ]
)
