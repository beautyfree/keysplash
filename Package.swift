// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeySplash",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "KeySplash", targets: ["KeySplash"])],
    targets: [.executableTarget(name: "KeySplash")]
)
