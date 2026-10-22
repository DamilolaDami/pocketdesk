// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PocketDeskKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "PDProtocol", targets: ["PDProtocol"]),
        .library(name: "PDSecurity", targets: ["PDSecurity"]),
        .library(name: "PDTransport", targets: ["PDTransport"]),
        .library(name: "PDHostCore", targets: ["PDHostCore"]),
        .library(name: "PDClientCore", targets: ["PDClientCore"]),
    ],
    targets: [
        // Pure: wire format shared by host, client and (later) the relay. No Apple frameworks.
        .target(name: "PDProtocol"),
        // Pairing + key agreement (CryptoKit).
        .target(name: "PDSecurity"),
        // Channel abstractions + QUIC implementation (Network.framework).
        .target(name: "PDTransport", dependencies: ["PDProtocol"]),
        // macOS host engines: capture, encode, input injection, permissions.
        .target(name: "PDHostCore", dependencies: ["PDProtocol", "PDSecurity", "PDTransport"]),
        // iOS client: session state machine, decode, render.
        .target(name: "PDClientCore", dependencies: ["PDProtocol", "PDSecurity", "PDTransport"]),

        .testTarget(name: "PDProtocolTests", dependencies: ["PDProtocol"]),
        .testTarget(name: "PDSecurityTests", dependencies: ["PDSecurity"]),
        .testTarget(name: "PDClientCoreTests", dependencies: ["PDClientCore"]),
    ]
)
