# Privacy Policy — Tortuga

_Last updated: 2026-11-24_

Tortuga ("the extension") is a browser extension for Chrome and Firefox that
routes your browser through the Tor network, using the
Tortuga helper, a program installed on your computer. This policy explains what
data the extension and the helper handle and how.

## Summary

**Tortuga does not collect, store, sell, or transmit your personal data to us
or to any third party for tracking or advertising.** It has no account, no
analytics and no server of its own. Your settings stay on your own device.

## Data stored locally

The extension saves the following with the browser's local storage
(`storage.local`, and `localStorage` for the theme):

- Whether Tor is on, and which bridge you picked
- obfs4 and WebTunnel bridge lines you fetched or pasted
- Your light or dark theme choice

The helper keeps, in its own data folder on your computer:

- Tor's directory cache and state (public information about Tor relays)

Nothing in this section is sent to us.

## Network connections

- **The Tor network.** While Tor is on, the helper connects to Tor relays, or
  to the bridge you picked, and the pages you open go through them. In
  Firefox, each site gets its own circuit. In Chrome, only Incognito windows
  go through Tor. The Tor Project's servers and volunteers' relays see what
  any Tor connection shows them; Tortuga adds nothing.
- **bridges.torproject.org**, only when you click **Get obfs4 lines** or
  **Get WebTunnel lines** on the settings page, to fetch bridge addresses. The
  request goes through Tor when Tor is on.

No other analytics, telemetry, or tracking requests are made.

## Permissions

The extension requests browser permissions only to provide its features:

- **proxy** — send your traffic through the helper's Tor connection
- **privacy** — while Tor is on, stop WebRTC from revealing your real IP, and
  in Firefox turn on `resistFingerprinting`; both are put back when Tor is
  turned off
- **nativeMessaging** — talk to the Tortuga helper on your computer
- **storage** — save your settings locally
- **tabs** (Firefox) — show the route for the site in the current tab
- **host access to all sites** (Firefox) — route every site through Tor

## The Mac app

Tortuga for Mac (on the Mac App Store as "Tortuga: Tor for Mac") runs Tor in
its network extension on your Mac and sends the apps you choose through it.

- **Stored on your Mac, never sent to us:** whether Tor is on, your bridge
  choice and bridge lines, and the list of apps that go through Tor (in the
  app's own container); Tor's directory cache and state (in the extension's
  container).
- **Kept only in memory, never stored or sent:** which apps are connecting,
  how many connections each has, and the Tor relays of each route, to draw
  the map and the app list; the names of apps that connected directly in the
  last hour, for the "Going direct" list. All of it is gone when Tor is
  turned off or the Mac restarts.
- **Network connections:** the apps in your list connect through the Tor
  network (or the bridge you picked); other apps connect as usual and
  Tortuga doesn't touch their traffic. Bridge lines are fetched from
  bridges.torproject.org only when you ask for them, through Tor.
- No analytics, no crash reporting, no account and no servers of our own.

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
