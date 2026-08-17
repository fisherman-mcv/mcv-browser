// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MCVBrowser",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2")
    ],
    targets: [
        .executableTarget(
            name: "MCV",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/MCV",
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("Carbon"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
            ]
        ),
        .testTarget(name: "MCVTests", dependencies: ["MCV"], path: "Tests/MCVTests")
    ]
)
