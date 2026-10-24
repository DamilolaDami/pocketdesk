# Relay (not started)

Lets a paired iPhone reach its Mac when they're not on the same network. The full design,
including the protocol, security model and step-by-step plan, is in
[docs/RELAY.md](../../docs/RELAY.md).

In short:

- Both devices connect to the relay with their existing device certificates. The Mac publishes
  which iPhones may reach it, and the relay only introduces those.
- The relay helps them connect directly (hole punching), and forwards packets only when that
  fails.
- The iPhone and Mac keep their normal QUIC session, end to end encrypted with pinned keys, so
  the relay only ever handles ciphertext.
- Candidate stack: Rust (`quinn`) or Go (`quic-go`), deployed near users. The relay protocol's
  types live in `Packages/PocketDeskKit/Sources/PDProtocol`, which stays free of Apple
  frameworks so this server can mirror it.
