// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFResize",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PDFResizeCore", targets: ["PDFResizeCore"]),
        .executable(name: "PDFResize", targets: ["PDFResize"])
    ],
    targets: [
        .target(
            name: "PDFResizeCore",
            path: "Sources/PDFResizeCore",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Quartz"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UserNotifications"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "PDFResize",
            dependencies: ["PDFResizeCore"],
            path: "Sources/PDFResize"
        ),
        .testTarget(
            name: "PDFResizeTests",
            dependencies: ["PDFResizeCore"],
            path: "Tests/PDFResizeTests"
        )
    ]
)
