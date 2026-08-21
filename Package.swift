// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotoOrganizer",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0")
    ],
    targets: [
        .executableTarget(
            name: "PhotoOrganizer",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/PhotoOrganizer"
        ),
        .testTarget(
            name: "PhotoOrganizerTests",
            dependencies: ["PhotoOrganizer"],
            path: "Tests/PhotoOrganizerTests"
        )
    ]
)
