// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScanStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScanStudio",
            path: "Sources/ScanStudio",
            linkerSettings: [
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
