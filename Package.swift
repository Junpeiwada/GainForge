// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GainForge",
    platforms: [
        // ISO ゲインマップ対応のため macOS 15 以降を要求する。
        .macOS(.v15)
    ],
    products: [
        .library(name: "GainForgeCore", targets: ["GainForgeCore"]),
        .executable(name: "gainforge", targets: ["GainForgeCLI"]),
    ],
    targets: [
        // 変換ロジックを一元化するコアライブラリ。CLI / GUI から共通利用する。
        .target(
            name: "GainForgeCore"
        ),
        // CLI は Core を import するだけの薄い実行可能ターゲット。
        .executableTarget(
            name: "GainForgeCLI",
            dependencies: ["GainForgeCore"]
        ),
        // 変換正当性の回帰テスト。
        .testTarget(
            name: "GainForgeCoreTests",
            dependencies: ["GainForgeCore"]
        ),
    ]
)
