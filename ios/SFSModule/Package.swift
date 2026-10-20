// swift-tools-version:5.9
// Solo para probar el cerebro SFS (Sources/Core) con `swift test` en la Mac de GitHub.
// La app se compila con Bazel (BUILD), no con este archivo.
import PackageDescription

let package = Package(
    name: "SFSCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    targets: [
        .target(name: "SFSCore", path: "Sources/Core"),
        .testTarget(name: "SFSCoreTests", dependencies: ["SFSCore"], path: "Tests/SFSCoreTests"),
    ]
)
