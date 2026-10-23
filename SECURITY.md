# Security policy

A paired phone can see and control a Mac, so security problems in PocketDesk matter. Thank you
for reporting them responsibly.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub instead: on this
repository's **Security** tab, choose **Report a vulnerability**.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get
an answer as soon as possible, and we aim for within a week. Once it's fixed, we'll credit you in the release notes unless you'd
rather not be named.

## What's in scope

- Pairing, device identity and the trust store (`PDSecurity`)
- The QUIC/TLS connection and certificate pinning (`PDTransport`)
- Anything that lets a device that isn't paired see the screen, send input or run actions
- Anything that lets a paired phone do more than it should (open local files by path, say)
- The Mac host's permissions and what it exposes

How the security is designed is described in the Security section of
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Supported versions

Only the latest release, and `main`, get security fixes.
