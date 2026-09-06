// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Studio",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Studio", targets: ["Studio"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.43.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
    ],
    targets: [
        .executableTarget(
            name: "Studio",
            dependencies: [
                "StudioConfiguration",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationIO", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "SystemPackage", package: "swift-system")
            ],
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("Network"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .target(name: "StudioConfiguration", dependencies: [.product(name: "Yams", package: "Yams")]),
        .testTarget(name: "StudioConfigurationTests", dependencies: ["StudioConfiguration"], resources: [.copy("Fixtures")]),
        .testTarget(name: "StudioTests", dependencies: ["Studio"])
    ]
)
