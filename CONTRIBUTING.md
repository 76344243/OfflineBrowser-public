# Contributing

Thank you for helping improve OfflineBrowser. Small, focused pull requests are
welcome, especially when they include a reproducible fixture or test.

## Before opening a pull request

- Build the `OfflineBrowser` scheme for an iOS Simulator.
- Run `git diff --check`.
- Keep credentials, private archives, personal browser data, generated media,
  and deployment-specific hostnames out of commits.
- Update `THIRD_PARTY_NOTICES.md` when adding or replacing a dependency.
- Do not make the optional Browsertrix service a requirement for the local
  archive engine.

Changes to Browsertrix integration should preserve these boundaries:

- the app remains useful when no crawler configuration is bundled;
- remote jobs are explicit and cancellable;
- completed archives are hash-verified before being stored locally;
- replay does not silently fall back to the live website;
- the service never receives an app signing credential or a private archive.

Please describe what you tested and what still requires device or deployment
validation. The project is intentionally conservative about claims for
arbitrary websites.
