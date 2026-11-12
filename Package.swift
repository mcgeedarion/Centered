// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Centered",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Centered",
            targets: ["Centered"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Centered",
            path: "Centered",
            exclude: [
                "Assets.xcassets",
                "Base.lproj",
                "Centered.entitlements",
                "Info.plist"
            ]
        ),
        .testTarget(
            name: "CenteredTests",
            dependencies: ["Centered"],
            path: "CenteredTests"
        )
    ]
)
