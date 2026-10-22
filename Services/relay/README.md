# Relay (not started)

Phase 2. Lets the phone reach the Mac when they're not on the same network.

- Rendezvous: both devices register with their pinned public keys; the relay brokers a
  direct QUIC path (UDP hole punching) and only forwards bytes when that fails.
- Forwarded traffic is already end-to-end encrypted between the paired devices, so the relay
  sees ciphertext only.
- Candidate stack: Rust (quinn) or Go (quic-go), deployed on Fly.io near users.
- Reuses the wire format in `Packages/PocketDeskKit/Sources/PDProtocol`; keep that module
  free of Apple frameworks so it can be mirrored or code-generated for the server.
