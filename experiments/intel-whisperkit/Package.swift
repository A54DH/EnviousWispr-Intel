// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Read, never modify, the app's lockfile. Test exactly the dependencies it ships.
struct AppLock: Decodable {
    struct Pin: Decodable {
        struct State: Decodable { let revision: String }
        let identity: String
        let location: String
        let state: State
    }
    let pins: [Pin]
}
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let lock = try JSONDecoder().decode(
    AppLock.self, from: Data(contentsOf: repositoryRoot.appendingPathComponent("Package.resolved"))
)
func dependency(_ identity: String) -> Package.Dependency {
    guard let pin = lock.pins.first(where: { $0.identity == identity }) else {
        fatalError("Missing app dependency pin: \(identity)")
    }
    return .package(url: pin.location, revision: pin.state.revision)
}

let package = Package(
    name: "IntelWhisperProbe",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "intel-whisper-probe", targets: ["IntelWhisperProbe"])],
    dependencies: [
        dependency("argmax-oss-swift"),
        // Pin the only transitive package too; do not silently test a newer version.
        dependency("swift-argument-parser"),
    ],
    targets: [
        .executableTarget(
            name: "IntelWhisperProbe",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        )
    ],
    swiftLanguageModes: [.v5]
)
