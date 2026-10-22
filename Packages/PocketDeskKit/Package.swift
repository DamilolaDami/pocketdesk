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
    dependencies: [
        // Apache-2.0. Builds the self-signed device certificates QUIC/TLS needs.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
    ],
    targets: [
        // Pure: wire format shared by host, client and (later) the relay. No Apple frameworks.
        .target(name: "PDProtocol"),
        // Device identity (keychain key + self-signed cert), pinning and pairing.
        .target(name: "PDSecurity", dependencies: [
            .product(name: "X509", package: "swift-certificates"),
        ]),
        // Channel abstractions + QUIC implementation (Network.framework) + Bonjour.
        .target(name: "PDTransport", dependencies: ["PDProtocol", "PDSecurity"]),
        // macOS host engines: capture, encode, input injection, permissions.
        .target(name: "PDHostCore", dependencies: ["PDProtocol", "PDSecurity", "PDTransport"]),
        // iOS client: session state machine, discovery, decode, render.
        .target(name: "PDClientCore", dependencies: ["PDProtocol", "PDSecurity", "PDTransport"]),

        .testTarget(name: "PDProtocolTests", dependencies: ["PDProtocol"]),
        .testTarget(name: "PDSecurityTests", dependencies: ["PDSecurity"]),
        .testTarget(name: "PDTransportTests", dependencies: ["PDTransport"]),
        .testTarget(name: "PDHostCoreTests", dependencies: ["PDHostCore", "PDTransport"]),
        // Uses the host's encoder to produce real HEVC for the client's assembler/decoder.
        .testTarget(name: "PDClientCoreTests", dependencies: ["PDClientCore", "PDHostCore", "PDSecurity"]),
    ]
)
