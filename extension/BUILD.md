# Building the Tortuga extension

The extension is TypeScript bundled with [Vite](https://vitejs.dev) (open
source). One code base builds both browsers; `TARGET=firefox` selects the
Firefox manifest and code paths at build time.

## Requirements

- Node.js 20 or later and npm (released builds: Node 26.13.0, npm 11.20.0)
- `zip` and `git` for the packaging scripts

## Firefox (addons.mozilla.org)

From `tortuga-firefox-<version>-source.zip` (the `extension/` folder of the
repository at the released commit):

```sh
cd extension
npm ci
npm run build:firefox
```

`dist-firefox/` is the extension: the same files as `tortuga-firefox-<version>.zip`.
`npm run lint:firefox` runs `web-ext lint`.

## Chrome (Chrome Web Store)

```sh
npm ci
npm run package    # → tortuga-chrome-<version>.zip (dist/ without manifest "key")
```

## What ends up in the package

| Output | Built from |
|---|---|
| `background.js` | `src/background/` |
| `links.js` | `src/content/links.ts` (catches clicks on torrent links) |
| `popup.html/js/css` | `src/popup/`, `src/styles/` |
| `options.html/js/css` | `src/options/` |
| `confirm.html/js/css` | `src/confirm/` |
| `theme.js` | `src/lib/theme-boot.ts` |
| `fonts/` | `public/fonts/` (Twemoji country flags, CC-BY 4.0) |
| `icons/` | `public/icons/`, rendered from `icons/*.svg` by `scripts/icons.mjs` |

Third-party code bundled: `tldts` (public suffix list, MIT).

## The helper

The extension does nothing without the Tortuga helper, a separate program
(`helper/` in the repository, Rust) that the browser starts through native
messaging. It is not part of the extension package; it ships as installers
on the GitHub releases page.
