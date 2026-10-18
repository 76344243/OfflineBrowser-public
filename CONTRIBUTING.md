# Contributing to OfflineBrowser

Thank you for helping improve OfflineBrowser. The project is maintained as an
experimental iOS/iPadOS application, so small, focused changes are easier to
review and verify than broad rewrites.

## Before opening a pull request

1. Read the public README and check whether the proposed behavior fits the
   documented compatibility and privacy boundaries.
2. Keep changes limited to the stated problem.
3. Add or update a deterministic test when changing archive, URL mapping,
   persistence, networking, or viewer behavior.
4. Run the unsigned simulator build locally.
5. Remove generated build products and personal data from the change.

## Local verification

Use the build command in the README. The fixture server is:

```sh
python3 -m http.server 19791 --bind 127.0.0.1 --directory TestSites
```

The simulator checks require a booted simulator. A simulator result does not
prove behavior on a physical device, while background execution, lock-screen
audio, Bluetooth interruptions, and large downloads are still device-specific.

## Scope and data rules

Do not commit:

- website archives or downloaded resources;
- audio collections, model files, or personal documents;
- passwords, bearer tokens, private endpoints, or signing credentials;
- site-specific staging scripts or private media adapters;
- Xcode user state, build products, screenshots, or generated reports;
- copied third-party site code unless its redistribution rights are clear.

Use small synthetic fixtures under `TestSites` for reproducible tests.

## Pull requests

Describe the user-visible behavior, the affected boundary, the verification
performed, and any remaining device-only limitations. Please do not submit
automated or cosmetic changes merely to increase contribution counts.
