# OfflineBrowser

Private, local-first website archiving for iPhone and iPad.

OfflineBrowser is a SwiftUI application for preserving websites on the device
and opening them again without an internet connection. It offers two
complementary capture paths:

- **Local archive engine** — the default path; no server is required. It
  discovers resources from a website, stores content by hash, verifies the
  result, and serves it through a local WebKit viewer.
- **Optional Browsertrix capture** — an explicit server-assisted path for
  JavaScript-heavy pages, embedded frames, and lazy-loaded content. A private
  Browsertrix service creates a WACZ archive; the app verifies and stores that
  archive locally for offline replay.

The second path is an extension, not a hidden dependency. A fresh checkout can
build and use the local archive engine without any crawler account, server, or
configuration file.

## Status

This is an early public release of a working research and engineering project.
The repository contains the generic application source, deterministic local
fixtures, the optional service adapter, and the relevant third-party notices.
The simulator build and repository checks are reproducible here. Compatibility
with arbitrary sites, long-running background captures, large archives, and
specific production deployments still requires validation in the relevant
environment.

## Highlights

- SwiftUI interface for iOS and iPadOS 17 or later.
- Full local capture with progress, pause, resume, retry, and SHA-256
  verification.
- Continuous saving of resources while a site is being used.
- Original URL paths and SPA navigation state preserved where the site permits
  it.
- Separate handling of first-party and explicitly allowed foreign origins.
- Atomic refresh generations that keep the previous local archive when a
  refresh is interrupted.
- Optional Browsertrix depth control and WACZ replay through bundled
  ReplayWeb.page assets.
- Local storage accounting, controlled recovery after storage errors, and a
  clear offline mode.

The managed viewer deliberately makes compatibility boundaries visible. Web
workers, service workers, WebSockets, EventSource, Beacon, and WebRTC are
restricted in the local viewer. Strict origin, CSP, CORS, encoding,
cross-origin frame, and JavaScript assumptions can make an arbitrary website
incompatible with local capture or replay.

## Quick start

Requirements:

- macOS with Xcode and an iOS/iPadOS 17 or later SDK;
- an iPhone or iPad simulator, or a device signed with your own team;
- SwiftSoup 2.13.9, resolved through Swift Package Manager.

Open `OfflineBrowser.xcodeproj`, select the **OfflineBrowser** scheme, choose a
simulator, and run. A physical device requires your own signing team and bundle
identifier.

The unsigned simulator build can be checked with:

```sh
xcodebuild -project OfflineBrowser.xcodeproj -scheme OfflineBrowser \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

## Optional Browsertrix setup

The app does not require Browsertrix. To enable it for a build, copy
`OfflineBrowser/Resources/CrawlerConfig/config.example.plist` to
`config.plist` and set the HTTPS endpoint and bearer token for your own service.
The real file is ignored by Git.

The deployment adapter and generic instructions are in
[`server/browsertrix/`](server/browsertrix/). The service should run behind an
HTTPS reverse proxy, with the Python listener bound to loopback and the token
stored outside Git. It uses a pinned Browsertrix Crawler image and returns a
WACZ archive only after integrity checks. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) before deploying it.

## Local fixtures and verification

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

The repository's verification helpers exercise the local archive path and do
not require a live crawler deployment. They do not replace testing on physical
hardware. Background execution, lock-screen behavior, external displays,
Dynamic Type, VoiceOver, very large downloads, and production crawler
retention policies require additional validation.

## Project layout

- `OfflineBrowser/` — SwiftUI application, local archive engine, and optional
  Browsertrix client/replay integration;
- `OfflineKit/` — manifest schema and static-site preparation helpers;
- `TestSites/` — synthetic fixtures used by local checks;
- `server/browsertrix/` — optional, generic service adapter and deployment
  examples;
- `OfflineBrowserUITests/` and `OfflineBrowser/Verification/` — UI and
  in-app verification code;
- `scripts/` — local validation helpers.

## Scope and privacy

This repository intentionally contains no private website archives, generated
media collections, credentials, personal browser data, signing material, or
deployment-specific hostnames. The optional service receives only the URL and
crawl settings needed for a submitted job. Completed WACZ data is downloaded
to the device and replayed locally.

Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) before submitting changes and
[`SECURITY.md`](SECURITY.md) for private vulnerability reports.

## License

The original project code is released under the MIT License; see
[`LICENSE`](LICENSE). Bundled ReplayWeb.page assets and the optional
Browsertrix runtime have separate notices documented in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
