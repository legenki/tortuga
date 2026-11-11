Tortuga sends your browser through Tor, draws the route each site takes, and downloads torrents from links. It hides your IP; it is not Tor Browser. See the [README](https://github.com/legenki/tortuga#readme) for what it does and doesn't do.

## Install the helper

The helper is the small program that runs Tor and downloads torrents. Pick the file for your system below.

| System | File | How |
|---|---|---|
| **macOS** (Apple silicon and Intel) | `Tortuga-Helper-{{VERSION}}-macos.pkg` | Open it and follow the installer. It installs for your user only and doesn't ask for an admin password. |
| **Debian, Ubuntu** (x86-64) | `tortuga-helper_{{VERSION}}_amd64.deb` | `sudo apt install ./tortuga-helper_{{VERSION}}_amd64.deb` |
| **Debian, Ubuntu** (ARM64) | `tortuga-helper_{{VERSION}}_arm64.deb` | `sudo apt install ./tortuga-helper_{{VERSION}}_arm64.deb` |
| **Windows** (x86-64) | `Tortuga-Helper-{{VERSION}}-windows-x86_64.zip` | Unzip, then run `powershell -ExecutionPolicy Bypass -File install.ps1` in that folder. No admin rights needed. |

If macOS won't open the installer because it can't check the developer, open **System Settings → Privacy & Security** and choose **Open Anyway**.

Upgrading from 0.2.0 or older on macOS? Those versions installed for every user. Remove the old copy with `sudo "/Library/Application Support/Tortuga/uninstall.sh"`; the new one works either way, since browsers use the per-user one first.

## The extension

**Chrome, before the store listing:** download `tortuga-chrome-{{VERSION}}-unpacked.zip` and unzip it into a folder you'll keep (Chrome loads the extension from that folder). Open `chrome://extensions`, turn on **Developer mode**, choose **Load unpacked** and select the folder. Then click **Details** under Tortuga and turn on **Allow in Incognito**. Use this zip, not `tortuga-chrome-{{VERSION}}.zip`: only the unpacked one gets the extension ID the helper accepts.

`tortuga-chrome-{{VERSION}}.zip` and `tortuga-firefox-{{VERSION}}.zip` are the packages sent to the Chrome Web Store and Firefox Add-ons. Install the extension from the stores once it's listed there; store reviews can take a few days after a release. `tortuga-firefox-{{VERSION}}-source.zip` is the source for Mozilla's reviewers.

## Good to know

- **Torrents don't go through Tor.** They download from your own IP, and other people in the swarm can see it.
- **In Chrome, only Incognito windows go through Tor**, on one shared circuit. Firefox sends the whole browser, with a separate circuit for each site.
