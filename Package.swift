// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScanStudio",
    defaultLocalization: "it",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "ScanStudio",
            path: "Sources/ScanStudio",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
            ]
        ),
        .testTarget(name: "ScanStudioTests", dependencies: ["ScanStudio"])
    ],
    swiftLanguageVersions: [.v5]
)
