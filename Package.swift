// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Distribution builds may opt into the signed Sparkle update framework.
let includeSparkle = ProcessInfo.processInfo.environment["PM_ENABLE_SPARKLE"] == "1"

let package = Package(
    name: "ProxyMirror",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ProxyMirror", targets: ["ProxyMirror"]),
        .executable(name: "ProxyMirrorScriptWorker", targets: ["ProxyMirrorScriptWorker"]),
        .executable(name: "ProxyMirrorSystemProxyHelper", targets: ["ProxyMirrorSystemProxyHelper"]),
        .executable(name: "ProxyMirrorTransparentExtension", targets: ["ProxyMirrorTransparentExtension"]),
    ],
    dependencies: [
        .package(path: "ProxyMirrorBridgeKit"),
        // X.509 证书生成（CA + 动态叶子证书）
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        // 数据面：TCP 代理 + TLS 原地升级（MITM）
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", exact: "1.38.0"),
    ] + (includeSparkle ? [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")] : []),
    targets: [
        // 核心库：代理引擎 + 数据层 + 系统集成 + UI 组件
        .target(
            name: "ProxyMirrorCore",
            dependencies: [
                "ProxyMirrorAuthorizedInstaller",
                "ProxyMirrorSystemProxy",
                "ProxyMirrorZstd",
                "ProxyMirrorProtocolSupport",
                .product(name: "ProxyMirrorBridgeKit", package: "ProxyMirrorBridgeKit"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ] + (includeSparkle ? [.product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))] : []),
            path: "Sources/ProxyMirrorCore",
            resources: [.process("Resources")]
        ),
        // 应用壳
        .executableTarget(
            name: "ProxyMirror",
            dependencies: ["ProxyMirrorCore"],
            path: "Sources/ProxyMirror",
            linkerSettings: includeSparkle ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                                         "-Xlinker", "-headerpad_max_install_names"], .when(platforms: [.macOS]))] : []
        ),
        .executableTarget(name: "ProxyMirrorScriptWorker"),
        .target(name: "ProxyMirrorZstd", exclude: ["LICENSE", "UPSTREAM.md"]),
        .target(name: "ProxyMirrorProtocolSupport"),
        .target(name: "ProxyMirrorAuthorizedInstaller"),
        .target(name: "ProxyMirrorSystemProxy"),
        .executableTarget(name: "ProxyMirrorSystemProxyHelper", dependencies: ["ProxyMirrorSystemProxy"]),
        .executableTarget(name: "ProxyMirrorTransparentExtension"),
        .target(
            name: "ProxyMirrorCoreChecks",
            dependencies: [
                "ProxyMirrorCore",
                "ProxyMirrorSystemProxy",
                .product(name: "ProxyMirrorBridgeKit", package: "ProxyMirrorBridgeKit"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Tests/ProxyMirrorCoreChecks"
        ),
        .testTarget(
            name: "ProxyMirrorCoreTests",
            dependencies: ["ProxyMirrorCoreChecks"]
        ),
        .testTarget(
            name: "ProxyMirrorPerformanceTests",
            dependencies: ["ProxyMirrorCoreChecks"]
        ),
        // 自测工具（CLT 环境无 XCTest platform，用可执行目标替代 swift test）
        .executableTarget(
            name: "ProxyMirrorSelfTest",
            dependencies: [
                "ProxyMirrorCore",
                "ProxyMirrorCoreChecks",
                "ProxyMirrorSystemProxy",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            ],
            path: "Sources/ProxyMirrorSelfTest"
        ),
    ]
)
