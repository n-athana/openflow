// swift-tools-version: 6.0
// Parakeet (FluidAudio, Core ML on the Neural Engine) over the asr/bench_wer.py test set.
import PackageDescription

let package = Package(
    name: "parakeet-bench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2")],
    targets: [
        .executableTarget(name: "parakeet-bench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
