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
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4")
    ],
    targets: [
        .executableTarget(
            name: "Studio",
            dependencies: [
                "StudioConfiguration",
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
                .linkedFramework("Network")
            ]
        ),
        .target(name: "StudioConfiguration"),
        .testTarget(name: "StudioConfigurationTests", dependencies: ["StudioConfiguration"]),
        .testTarget(name: "StudioTests", dependencies: ["Studio"])
    ]
)
