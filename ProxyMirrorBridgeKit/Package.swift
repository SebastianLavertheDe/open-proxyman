// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProxyMirrorBridgeKit",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [.library(name: "ProxyMirrorBridgeKit", targets: ["ProxyMirrorBridgeKit"])],
    targets: [
        .target(name: "ProxyMirrorBridgeKit"),
        .testTarget(name: "ProxyMirrorBridgeKitTests", dependencies: ["ProxyMirrorBridgeKit"]),
    ]
)
