// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MCVBrowser",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MCV",
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
        )
    ]
)
