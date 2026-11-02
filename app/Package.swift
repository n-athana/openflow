// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenFlow",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Parakeet on the Neural Engine for transcription mode's final text (FinalPass.swift).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
    ],
    targets: [
        .executableTarget(
            name: "OpenFlow",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/OpenFlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
