# Pairing reliability follow-up

The reported failure occurs before the six-digit verification code. The reporter's
phone app version is not yet known, so the specific customer cause is not confirmed.
At investigation time, the public Mac download was 1.2 (protocol 25), while Apple still
reported iPhone 1.2 (101) waiting for external beta review. The previous external phone
build was 1.1 (81), protocol 21. These versions cannot negotiate the same streaming ALPN.
Mac 1.1 remains available as a compatible versioned download for iPhone 1.1 users.

QR pairing previously omitted the advertised-version check used by the Mac card.
It now checks the same protocol ordering before attempting a connection and tells the
person which app needs updating. The failure screen uses "Update needed" for that case.
Unknown advertised versions still use the authenticated handshake; certificate pinning,
invite-token validation and human verification are unchanged.

A separate deterministic approval-timeout bug was reproduced using ClientConnection
against a real local QUIC HostService. Mac approval was delayed by 18 seconds, within
the host's existing two-minute approval window. The unmodified client disconnected at
15.46 seconds before pairing completed. With transport-level QUIC keepalives enabled
for invite-based pairing connections, the same test passed at 18.88 seconds.
Keepalives send QUIC PING/ACK traffic rather than adding messages to the application
handshake. Normal connection defaults and approval deadlines are unchanged. No wire
format change or protocol bump is required.

Validation: 41 targeted tests passed, including the delayed-approval real-network
regression, version directions, wrong-token rejection, untrusted phones, and existing
host connections. The signed iPhone development build 104 succeeded. This fix has not
been uploaded to TestFlight as part of this investigation.

Apple reference: https://developer.apple.com/documentation/network/networkconnection/keepalive
