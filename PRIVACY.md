# Privacy Policy — Tortuga

_Last updated: 2026-11-05_

Tortuga ("the extension") is a browser extension for Chrome and Firefox that
routes your browser through the Tor network and downloads torrents, using the
Tortuga helper, a program installed on your computer. This policy explains what
data the extension and the helper handle and how.

## Summary

**Tortuga does not collect, store, sell, or transmit your personal data to us
or to any third party for tracking or advertising.** It has no account, no
analytics and no server of its own. Your settings stay on your own device.

## Data stored locally

The extension saves the following with the browser's local storage
(`storage.local`, and `localStorage` for the theme and last opened tab):

- Whether Tor is on, and which bridge you picked
- obfs4 and WebTunnel bridge lines you fetched or pasted
- The list of your torrent downloads (name, info hash, progress)
- Your light or dark theme choice, and which popup tab was open last

The helper keeps, in its own data folder on your computer:

- Tor's directory cache and state (public information about Tor relays)
- The state of your torrent downloads, so they can resume after a restart

Downloaded files are saved in `Downloads/Tortuga`. Nothing in this section is
sent to us.

## Network connections

- **The Tor network.** While Tor is on, the helper connects to Tor relays, or
  to the bridge you picked, and the pages you open go through them. In
  Firefox, each site gets its own circuit. In Chrome, only Incognito windows
  go through Tor. The Tor Project's servers and volunteers' relays see what
  any Tor connection shows them; Tortuga adds nothing.
- **bridges.torproject.org**, only when you click **Get obfs4 lines** or
  **Get WebTunnel lines** on the settings page, to fetch bridge addresses. The
  request goes through Tor when Tor is on.
- **Torrent peers, trackers and the DHT**, directly from your own IP and not
  through Tor, only while a torrent downloads or seeds. Other people in the
  swarm can see your IP address. Every place a download starts says so.
- **.torrent links** you choose to download are fetched by the helper, without
  your browser's cookies.

No other analytics, telemetry, or tracking requests are made.

## Permissions

The extension requests browser permissions only to provide its features:

- **proxy** — send your traffic through the helper's Tor connection
- **privacy** — while Tor is on, stop WebRTC from revealing your real IP, and
  in Firefox turn on `resistFingerprinting`; both are put back when Tor is
  turned off
- **nativeMessaging** — talk to the Tortuga helper on your computer
- **storage** — save your settings locally
- **contextMenus** — add "Download with Tortuga" to the menu of links
- **tabs** (Firefox) — show the route for the site in the current tab
- **host access to all sites** and the **content script** — route every site
  through Tor (Firefox), and notice clicks on magnet and .torrent links so
  Tortuga can ask whether to download them. The content script reads nothing
  else on the page and sends nothing anywhere.

## Data sharing

We do not share, sell, or rent your data. We do not have servers that receive
your data.

## Not affiliated with the Tor Project

Tortuga is not made by or affiliated with the Tor Project. "Tor" is a trademark
of The Tor Project, Inc.

## Children

Tortuga is not directed at children under 13.

## Changes

If this policy changes, the updated version will be posted at this URL with a
new "Last updated" date.

## Contact

For questions about this policy, contact: andylegenki@gmail.com
