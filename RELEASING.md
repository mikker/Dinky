# Releases

Versions are `X.Y`, bumped by 0.1 each release (0.9 is followed by 0.10 unless you ask for 1.0). User-visible changes go in `CHANGELOG.md` under `## Unreleased` as they land, written for users; the `dinky-release` skill in `.agents/skills` reviews the delta, the manual and those notes before a release.

Run `just release` from a clean `main` that matches `origin/main` (or `just release 1.0` to pick the version). It runs the tests, renames `## Unreleased` to `## 0.4`, sets `version:` in `docs/_config.yml` (the manual's front page shows it), commits and pushes `Release 0.4`, builds a universal release bundle for Apple silicon and Intel, signs it with your Developer ID Application identity with the hardened runtime, notarizes and staples it using the `TunaNotary` keychain profile, zips it to `dist/dinky.app.zip`, signs the zip for Sparkle and writes `dist/appcast.xml` with the `## 0.4` section of the changelog, rendered by GitHub, as the notes the update window shows, writes `dist/dinky.rb` from `scripts/dinky.rb.template`, tags `v0.4`, creates a draft GitHub release whose notes are the `## 0.4` section of the changelog, uploads the zip, the appcast and the cask, publishes it as latest, and pushes the cask to [mikker/homebrew-tap](https://github.com/mikker/homebrew-tap) through a temporary clone. Running it again without adding commits reuses the `Release 0.4` commit and retries a failed release or tap update; a published version is never replaced.

`just package 0.4` does everything up to and including the zip, appcast and cask without publishing. Override `NOTARYTOOL_PROFILE` or `DEVELOPER_ID_APPLICATION` when needed. The build number is the commit count plus 100.

Release bundles use `swift build -c release --jobs 4 --arch arm64 --arch x86_64`, with the same flags for `--show-bin-path` rather than assuming a SwiftPM output directory. `scripts/bundle.sh --debug` stays native for local development. Both architectures support macOS 15 or later; Intel Macs stop at macOS 26.

`scripts/check-universal.sh path/to/dinky.app` checks both slices in the main executable, Sparkle framework, Autoupdate, Updater, Downloader and Installer. Bundling runs it before signing; packaging repeats it before notarization and on the unpacked shipping zip before generating the architecture-unrestricted cask. Add any new bundled executables to this check. The appcast still derives its architecture requirement from the executable, so an arm64-only source build cannot offer an incompatible update to Intel Macs.

Run `python3 -m unittest discover -s scripts/tests -v` for isolated packaging regressions (also part of `just test` and CI). These mock build/signing/notarization commands; a real release still needs Developer ID signature verification, notarization, Gatekeeper assessment and a Sparkle update smoke test on each architecture.

## Updates

dinky updates itself with [Sparkle](https://sparkle-project.org) (SwiftPM package, `Sparkle.framework` in `Contents/Frameworks`, signed inside out by `scripts/bundle.sh`). The feed, `SUFeedURL` in `Resources/Info.plist`, is https://github.com/mikker/Dinky/releases/latest/download/appcast.xml: the `appcast.xml` asset of the latest release, so publishing a release is what ships the update. `scripts/appcast.py` writes it from the built app and the zip.

Updates are signed with an EdDSA key whose private half lives in the login Keychain under the account `com.brnbw.dinky`; `sign_update --account com.brnbw.dinky` uses it during packaging. The public key, `SUPublicEDKey`, is `jif/E57Xw8xCo7BwHnOeASD+nbQc462aQTYOuvoH/io=`. Losing the private key means installed copies can no longer update, so keep a backup somewhere safe:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x dinky-sparkle-key --account com.brnbw.dinky
```

Import it on another Mac with `generate_keys -f dinky-sparkle-key --account com.brnbw.dinky`.
