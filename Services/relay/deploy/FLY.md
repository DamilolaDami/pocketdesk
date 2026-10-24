# Fly.io single-instance deployment

Deploy from `Services/relay`. The checked-in `fly.toml` uses one 512MB Machine in London,
a dedicated IPv4, a 1GB `relay_certs` volume, UDP 4433 for Quinn, and 32 explicit forwarding
ports (50000–50031). State is local to the Machine: **do not add replicas or regions**.
There is no public UDP IPv6/shared-IPv4 support on Fly. Deployments use the immediate
strategy and interrupt sessions; clients need to reconnect/retry afterwards.

The configured hostname is `relay.pocketdesk.runmira.dev`, in the Cloudflare-managed
`runmira.dev` zone. The Fly organization is Charly (`charly-27`).

The deployed dedicated IPv4 is `188.93.144.123`. The DNS-only A record is
`relay.pocketdesk` in `runmira.dev`.

Current verification: Fly readiness and certificate issuance pass. The local Apple/Quinn
integration passes, but the public native probe still times out after host registration.
Forwarded video/audio/input through Fly is not yet verified; do not treat readiness alone
as proof that remote sessions work.

Both native outer QUIC and Quinn are capped at 1,200-byte UDP payloads. Quinn MTU discovery
and segmentation offload are disabled to keep packets within Fly's UDP transport limits.

## Provision and DNS

```sh
fly apps create pocketdesk-relay-dami --org charly-27
fly ips allocate-v4 --app pocketdesk-relay-dami
fly volumes create relay_certs --app pocketdesk-relay-dami --region lhr --size 1
```

These commands allocate billable resources. Create a **DNS-only A record** for the relay
hostname pointing at the dedicated IPv4. Disable Cloudflare proxying for this record,
and remove any conflicting AAAA record. Allow Let's Encrypt in the domain's CAA policy
if one is set. Keep TCP 80 public: it serves HTTP-01 certificate challenges.

```sh
fly config validate
fly deploy --ha=false
fly status
fly checks list
```

The readiness check stays unhealthy until Caddy obtains a trusted certificate and Quinn
starts. DNS must be pointed at the IPv4 before the first deploy can become healthy.
If the app name is taken, change `app` in `fly.toml` and all commands consistently.

## Native public relay probe

From the repository root on macOS, run the same pinned inner-session exercise used
by local integration against the deployed endpoint (normal system TLS validation):

```sh
POCKETDESK_RELAY_REMOTE=relay.pocketdesk.runmira.dev:4433 \
  swift test --package-path Packages/PocketDeskKit --scratch-path .build/relay-tests \
  --filter RelayIntegrationTests
```

The probe creates disposable device identities, checks unpaired rejection, forces LAN
fallback, transfers video/audio/input, and checks revocation. For diagnosing stale DNS,
`POCKETDESK_RELAY_REMOTE` can use the public IP with `POCKETDESK_RELAY_REMOTE_CERT_DER`
pointing to the deployed leaf certificate in DER form; that mode pins the certificate
and does not validate the hostname through system trust.

## Certificates and secrets

Caddy obtains and renews the public certificate on the Machine using HTTP-01. Its ACME
account and key/certificate files stay on `/data`; preserve this volume across deploys.
There is no need to send a private key through chat or store it in the repository.

Quinn reads Caddy's certificate/key directly. It checks for renewal every 60 seconds and
updates its TLS server config for new handshakes without terminating existing connections.
A temporarily incomplete/mismatched renewal leaves the previous good certificate active.
Caddy handles certificate issuance only; PocketDesk QUIC never passes through its TLS proxy.

The deployment resolves `fly-global-services` and binds **both** the control and forwarding
UDP sockets to that address. Every forwarding port is listed separately because Fly does
not rewrite UDP ports. Arbitrary OS-selected ephemeral forwarding ports won't work here.

## Verify before use

- Confirm the deployed image is for the intended git revision and that only one Machine runs.
- Check the domain resolves to the dedicated IPv4 and readiness is healthy.
- Verify a real Apple QUIC control handshake and a complete forwarded pinned session from
  outside Fly; an HTTP response alone does not prove the UDP path works.
- Configure `RELAY_HOSTNAME:4433` in both native apps, pair locally first, enable Remote Access
  on each and keep the Mac awake. Test from cellular with local Wi-Fi disabled.

Pricing includes the Machine, dedicated IPv4, volume and public egress. Video forwarding is
the main variable cost; monitor usage before using this for long streams. Remote access
still needs the pre-release privacy-policy update before public distribution.
