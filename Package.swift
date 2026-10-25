// swift-tools-version: 6.2

import PackageDescription
import Foundation

let localPackageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent(".build/local-packages", isDirectory: true)
let localFluidAudioDirectory = localPackageDirectory.appendingPathComponent("FluidAudio", isDirectory: true)
let localPeekabooDirectory = localPackageDirectory.appendingPathComponent("Peekaboo", isDirectory: true)
let hasBootstrappedLocalPackages = FileManager.default.fileExists(
    atPath: localFluidAudioDirectory.appendingPathComponent("Package.swift").path
) && FileManager.default.fileExists(
    atPath: localPeekabooDirectory.appendingPathComponent("Package.swift").path
)

let openClickyDependencies: [Package.Dependency] = hasBootstrappedLocalPackages
    ? [
        .package(path: localFluidAudioDirectory.path),
        .package(path: localPeekabooDirectory.path)
    ]
    : [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.17.7"
        ),
        .package(
            url: "https://github.com/openclaw/Peekaboo.git",
            exact: "4.9.6"
        )
    ]

let package = Package(
    name: "OpenClicky",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OpenClicky", targets: ["OpenClicky"])
    ],
    dependencies: openClickyDependencies,
    targets: [
        .executableTarget(
            name: "OpenClicky",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "PeekabooAutomationKit", package: "Peekaboo"),
                .product(name: "PeekabooFoundation", package: "Peekaboo")
            ],
            path: "leanring-buddy",
            exclude: [
                "AGENTS.md",
                "Assets.xcassets",
                "Info.plist",
                "leanring-buddy.entitlements"
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility")
            ]
        ),
        .testTarget(
            name: "OpenClickyTests",
            dependencies: ["OpenClicky"],
            path: "leanring-buddyTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
