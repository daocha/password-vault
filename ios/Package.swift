// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "VaultCore", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "VaultCore", targets: ["VaultCore"]), .executable(name: "vault-security-checks", targets: ["SecurityChecks"])],
    dependencies: [.package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0")],
    targets: [
        .target(name: "VaultCore", dependencies: [.product(name: "Clibsodium", package: "swift-sodium")]),
        .testTarget(name: "VaultCoreTests", dependencies: ["VaultCore"]),
        .executableTarget(name: "SecurityChecks", dependencies: ["VaultCore"])
    ]
)
