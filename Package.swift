// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PhotoOrganizer",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.10.0")
    ],
    targets: [
        .executableTarget(
            name: "PhotoOrganizer",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/PhotoOrganizer",
            resources: [
                .copy("Resources/CLIPModels")
            ]
        ),
        .testTarget(
            name: "PhotoOrganizerTests",
            dependencies: ["PhotoOrganizer", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/PhotoOrganizerTests"
        )
    ]
)
