// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dsh-proper",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DSHCore",
            path: "Sources/dsh",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "dsh",
            dependencies: ["DSHCore"],
            path: "Sources/dshApp"
        ),
        .testTarget(
            name: "dshTests",
            dependencies: ["DSHCore"],
            path: "Tests/dshTests"
        ),
    ]
)
