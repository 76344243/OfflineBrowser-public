# OfflineBrowser for iPhone and iPad

OfflineBrowser is an independent SwiftUI application for saving websites for
later use on iOS and iPadOS 17 or later. It preserves original URL paths while
serving archived resources through a local, session-protected WebKit viewer.

The project is experimental. It is not an App Store distribution, a complete
website backup guarantee, or a security proof for arbitrary hostile web code.

## What is included

This repository contains the generic application source, the `OfflineKit` file
format and preparation helpers, small local test sites, and deterministic
verification tests.

Private website archives, generated media collections, credentials, server
configuration, personal browser data, and device-signing material are not part
of the public project. Site-specific staging scripts and private media adapters
are intentionally not part of this public baseline. The generated `KitSites/`
directory is ignored by Git.

## Features

- Full archive generation with progress, pause, resume, and hash validation.
- Continuous saving of resources while a site is being used.
- Offline mode with a local loopback server and per-viewer authorization token.
- Preservation of the original document URL and the last visited SPA route.
- Separate handling of first-party and foreign origins.
- Atomic refresh generations that keep the previous archive when a refresh is
  interrupted.
- Local storage accounting and controlled recovery after storage errors.
- VoiceOver-oriented navigation and an iPhone/iPad SwiftUI interface.

The implementation deliberately documents its compatibility limits. Workers,
service workers, WebSockets, EventSource, Beacon, and WebRTC are blocked in the
managed viewer. Strict origin, CSP, CORS, encoding, cross-origin frame, and
JavaScript assumptions can make an arbitrary site incompatible.

## Requirements

- macOS with Xcode
- An iOS/iPadOS 17 or later SDK
- An iPhone or iPad simulator, or a device signed with your own team
- SwiftSoup 2.13.9, resolved through Swift Package Manager

## Run in Xcode

Open `OfflineBrowser.xcodeproj`, select the **OfflineBrowser** scheme, choose an
iPhone or iPad simulator, and run. A physical device requires your own signing
team and bundle identifier.

## Local test sites

The small fixtures under `TestSites` can be served locally:

```sh
python3 -m http.server 19791 --bind 127.0.0.1 --directory TestSites
```

In the simulator, open:

```text
http://127.0.0.1:19791/kit-static/index.html
http://127.0.0.1:19791/no-kit-static/index.html
```

On a physical device, use the Mac's LAN address instead of `127.0.0.1`.

## Build and verification

The unsigned simulator build can be checked with:

```sh
xcodebuild -project OfflineBrowser.xcodeproj -scheme OfflineBrowser \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

The simulator checks require a booted simulator and the locally served test
fixtures. They do not replace testing on physical hardware. In particular,
background execution, lock-screen behavior, Bluetooth/audio interruptions,
large downloads, iPad window modes, Dynamic Type, and VoiceOver still require
device validation.

## Project layout

- `OfflineBrowser/` — SwiftUI application and local archive engine
- `OfflineKit/` — manifest schema and static-site preparation helpers
- `TestSites/` — small synthetic fixtures used by tests
- `OfflineBrowserUITests/` — UI-level tests
- `OfflineBrowser/Verification/` — in-app architecture and integration checks
- `scripts/` — local validation helpers

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
Do not submit private website exports, copyrighted media collections,
credentials, personal archives, or generated build products.

## Security

Please see [SECURITY.md](SECURITY.md) for private vulnerability reporting.

## License

The project code is released under the MIT License. See [LICENSE](LICENSE).
Third-party notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
