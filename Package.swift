// swift-tools-version: 6.2
import PackageDescription

let targets: [Target] = [
    .binaryTarget(name: "SherpaOnnxLib", path: "Frameworks/sherpa-onnx.xcframework"),
    .executableTarget(
        name: "Type4Me",
        dependencies: ["SherpaOnnxLib"],
        path: "Type4Me",
        exclude: ["Resources"],
        cSettings: [.headerSearchPath("Bridge")],
        swiftSettings: [
            .swiftLanguageMode(.v5),
            .define("HAS_SHERPA_ONNX"),
        ],
        linkerSettings: [
            .linkedLibrary("c++"),
            .linkedFramework("Accelerate"),
            .linkedFramework("Foundation"),
        ]
    ),
    .testTarget(
        name: "Type4MeTests",
        dependencies: ["Type4Me"],
        path: "Type4MeTests"
    ),
]

let package = Package(
    name: "Type4Me",
    platforms: [.macOS(.v14)],
    targets: targets
)
