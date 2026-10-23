# PocketDesk

[![CI](https://github.com/DamilolaDami/pocketdesk/actions/workflows/ci.yml/badge.svg)](https://github.com/DamilolaDami/pocketdesk/actions/workflows/ci.yml)

Use your whole Mac from your phone, built for your thumb.

## Requirements

- Xcode 26+, iOS 26 / macOS 26 deployment targets
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Getting started

```bash
xcodegen            # generates PocketDesk.xcodeproj
open PocketDesk.xcodeproj
```

Run the shared logic tests without Xcode:

```bash
cd Packages/PocketDeskKit && swift test
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it works and
[CONTRIBUTING.md](CONTRIBUTING.md) for building, signing and testing.

## Security

Please report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## License

[Apache License 2.0](LICENSE).
