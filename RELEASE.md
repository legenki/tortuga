# Releasing Tortuga

A release is the helper's installers (GitHub release) and the extension
(Chrome Web Store, addons.mozilla.org). CI (`.github/workflows/release.yml`)
builds and tests everything on each push; a `v*` tag also publishes the
GitHub release.

## Once: pin the Chrome extension ID

Installers register the helper for one Chrome extension ID, so it must be
fixed before the first release:

1. Generate a key and keep it out of the repository (and backed up):
   `openssl genrsa -out ~/tortuga-chrome-key.pem 2048`
2. `python3 helper/packaging/hosts.py set-chrome-key ~/tortuga-chrome-key.pem`
   writes its public key into `extension/manifest.json` and prints the ID.
3. First upload to the Chrome Web Store: put a copy of the key, named
   `key.pem`, at the top of `tortuga-chrome-<version>.zip`, so the store keeps
   that ID. Check the ID in the developer dashboard against
   `python3 helper/packaging/hosts.py chrome-id`. If they differ, copy the
   dashboard's public key into `manifest.json` "key" instead and rebuild the
   installers.

## Once: macOS signing (optional, needed for Gatekeeper)

Add the secrets listed at the top of the workflow (a .p12 with the Developer
ID Application and Developer ID Installer certificates, its password, the
certificate names, Apple ID, team ID and an app-specific password). Without
them the .pkg is unsigned. Locally: `DEVELOPER_ID_APP=… DEVELOPER_ID_INSTALLER=…
NOTARY_PROFILE=… helper/packaging/macos/build-pkg.sh --universal`.

Set the repository variable `DEB_MAINTAINER` ("Name <email>") for the .deb.

## Each release

1. Bump the version in `helper/tortuga-helper/Cargo.toml`,
   `extension/package.json`, `extension/manifest.json`,
   `extension/manifest.firefox.json`; commit.
2. Tag and push: `git tag v<version> && git push origin main v<version>`.
3. CI publishes the release with `Tortuga-Helper-<v>-macos.pkg`,
   `tortuga-helper_<v>_amd64.deb`, `tortuga-helper_<v>_arm64.deb`,
   `Tortuga-Helper-<v>-windows-x86_64.zip` and the extension zips.
   Its notes are `.github/release-notes.md` (install steps; `{{VERSION}}`
   becomes `<v>`) followed by GitHub's list of changes.
4. Upload `tortuga-chrome-<v>.zip` to the Chrome Web Store and
   `tortuga-firefox-<v>.zip` with `tortuga-firefox-<v>-source.zip` to AMO
   (reviewers build it with `extension/BUILD.md`).
   The first store submission, listing texts and reviewer notes:
   [docs/PUBLISHING.md](docs/PUBLISHING.md).

README screenshots: `extension/scripts/live-check/run.sh screenshots` retakes
them into `docs/screenshots/` (light theme, Tor on, local paths hidden).

## Checks before tagging

```sh
(cd helper && cargo test -p tortuga-helper)
python3 -m unittest discover -s helper/packaging
(cd extension && npm test && npm run lint:firefox)
extension/scripts/live-check/run.sh && extension/scripts/live-check/run.sh downloads && extension/scripts/live-check/run.sh bridges
```

Local packages: `helper/packaging/macos/build-pkg.sh` (this Mac's arch,
unsigned), `helper/packaging/linux/docker-build.sh` (a .deb built and
installed in Docker; run it from a folder Docker can mount, e.g. under
/Users).
