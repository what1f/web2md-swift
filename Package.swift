// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Web2MD",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Web2MD", targets: ["Web2MD"]),
        .executable(name: "web2md", targets: ["Web2MDCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.0"),
    ],
    targets: [
        .target(name: "Web2MD", dependencies: ["SwiftSoup"]),
        .executableTarget(name: "Web2MDCLI", dependencies: ["Web2MD"]),
    ]
)
