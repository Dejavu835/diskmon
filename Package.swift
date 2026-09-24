// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "diskmon",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "diskmon", targets: ["diskmon"]),
        .library(name: "DiskMonCore", targets: ["DiskMonCore"])
    ],
    targets: [
        .target(
            name: "DiskMonIOKitSMART",
            path: "Sources/DiskMonIOKitSMART",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "DiskMonCore",
            path: "Sources/DiskMonCore"
        ),
        .testTarget(
            name: "DiskMonCoreTests",
            dependencies: ["DiskMonCore"],
            path: "Tests/DiskMonCoreTests"
        ),
        .executableTarget(
            name: "diskmon",
            dependencies: ["DiskMonIOKitSMART", "DiskMonCore"],
            path: "Sources/diskmon",
            exclude: [
                "Resources/Info.plist",
                "Resources/diskmon.entitlements"
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/Fonts"),
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj"),
                .copy("Resources/ntfskit.fs"),
                .copy("Resources/NTFSKit-LICENSE.GPL2")
            ],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
