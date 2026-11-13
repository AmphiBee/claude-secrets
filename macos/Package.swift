// swift-tools-version: 6.0
import PackageDescription

// Les Command Line Tools n'embarquent ni XCTest ni Swift Testing : les tests sont un
// exécutable (`swift run core-tests`), dans l'esprit de tests/run.py.
let package = Package(
    name: "ClaudeSecretsMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SecretsCore", path: "Sources/SecretsCore"),
        .executableTarget(name: "ClaudeSecrets", dependencies: ["SecretsCore"], path: "Sources/ClaudeSecrets"),
        .executableTarget(name: "spike", path: "Sources/Spike"),
        .executableTarget(name: "core-tests", dependencies: ["SecretsCore"], path: "Sources/CoreTests"),
    ]
)
