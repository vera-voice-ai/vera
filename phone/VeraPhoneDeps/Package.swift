// swift-tools-version: 6.0
// What the iPhone app links that is not Swift of ours: the C bridge to sherpa-onnx (ears: Silero VAD + GigaAM) and the
// two prebuilt frameworks it calls — sherpa-onnx and onnxruntime (the voice, app/ SileroVoice, runs on the same
// onnxruntime). Frameworks/ is not in git: scripts/phone-assets.sh fills it from ~/.vera03/build (build-ears-ios.sh).
import PackageDescription

let package = Package(
    name: "VeraPhoneDeps",
    platforms: [.iOS("26.0")],
    products: [.library(name: "CSherpaPhone", targets: ["CSherpaPhone"])],
    targets: [
        .binaryTarget(name: "sherpa_onnx", path: "Frameworks/sherpa-onnx.xcframework"),
        .binaryTarget(name: "onnxruntime", path: "Frameworks/onnxruntime.xcframework"),
        .target(name: "CSherpaPhone", dependencies: ["sherpa_onnx", "onnxruntime"], path: "CSherpaPhone",
                linkerSettings: [.linkedLibrary("c++")]),
    ]
)
