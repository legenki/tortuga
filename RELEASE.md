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

## Once: macOS signing (removes the "Open Anyway" step)

Without signing, Gatekeeper blocks the .pkg and people have to allow it in
System Settings → Privacy & Security, with their password. Signed and
notarised, it opens with a double click. CI signs as soon as the secrets
below exist; nothing else changes.

1. Join the Apple Developer Program (developer.apple.com, paid yearly).
2. In Xcode → Settings → Accounts → Manage Certificates (or on
   developer.apple.com → Certificates), create a **Developer ID Application**
   and a **Developer ID Installer** certificate.
3. In Keychain Access, select both certificates with their private keys and
   export them as one `.p12` with a password.
4. At appleid.apple.com → Sign-In and Security → App-Specific Passwords,
   make a password for notarisation. The team ID is on
   developer.apple.com → Membership.
5. Add the repository secrets (Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `APPLE_CERTIFICATES_P12` | `base64 -i certs.p12 \| pbcopy`, pasted |
   | `APPLE_CERTIFICATES_PASSWORD` | the `.p12` password |
   | `APPLE_ID` | your Apple ID email |
   | `APPLE_TEAM_ID` | the team ID |
   | `APPLE_APP_PASSWORD` | the app-specific password |
   | `DEVELOPER_ID_APP` | `Developer ID Application: Name (TEAMID)` |
   | `DEVELOPER_ID_INSTALLER` | `Developer ID Installer: Name (TEAMID)` |

   The two names are exactly as `security find-identity -v` prints them.
6. Push a tag; the macOS job logs `notarytool` accepting the package.
   Check a downloaded copy with `spctl -a -vv -t install Tortuga-Helper-<v>-macos.pkg`
   ("accepted, source=Notarized Developer ID").

Locally: `xcrun notarytool store-credentials tortuga …`, then
`DEVELOPER_ID_APP=… DEVELOPER_ID_INSTALLER=… NOTARY_PROFILE=tortuga
helper/packaging/macos/build-pkg.sh --universal`.

Set the repository variable `DEB_MAINTAINER` ("Name <email>") for the .deb.

## Each release

1. Bump the version in `helper/tortuga-helper/Cargo.toml`,
   `extension/package.json`, `extension/manifest.json`,
   `extension/manifest.firefox.json`; commit.
2. Tag and push: `git tag v<version> && git push origin main v<version>`.
3. CI publishes the release with `Tortuga-Helper-<v>-macos.pkg`,
   `tortuga-helper_<v>_amd64.deb`, `tortuga-helper_<v>_arm64.deb`,
   `Tortuga-Helper-<v>-windows-x86_64.zip` and the extension zips
   (`tortuga-chrome-<v>-unpacked.zip` keeps the pinned key, for people who
   load it by hand before the store listing).
   Its notes are `.github/release-notes.md` (install steps; `{{VERSION}}`
   becomes `<v>`) followed by GitHub's list of changes.
4. Upload `tortuga-chrome-<v>.zip` (not the `-unpacked` one) to the Chrome Web Store and
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
