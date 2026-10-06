// swift-tools-version:5.9

import PackageDescription

// RNNoise (https://github.com/xiph/rnnoise, BSD-3-Clause) vendored at
// 70f1d256acd4b34a572f999a05c87bf00b67730d — the library's C sources only.
// The model's weight tables are never compiled in: `USE_WEIGHTS_FILE` keeps
// them out, and the app downloads, verifies and loads the binary weights
// blob at runtime (see README.md).
let package = Package(
    name: "rnnoise",
    platforms: [.iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "CRNNoise", targets: ["CRNNoise"]),
    ],
    targets: [
        .target(
            name: "CRNNoise",
            path: "Sources/CRNNoise",
            cSettings: [
                .define("USE_WEIGHTS_FILE"),
                .define("RNNOISE_BUILD"),
                // The denoiser runs per 10 ms audio frame on the capture
                // thread; an -O0 Debug build of the GRU matrix math falls
                // behind realtime, so it is optimized in every configuration.
                .unsafeFlags(["-O3", "-Wno-shorten-64-to-32"]),
            ]
        ),
    ]
)
