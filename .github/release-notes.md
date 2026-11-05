Tortuga sends your browser through Tor, draws the route each site takes, and downloads torrents from links. It hides your IP; it is not Tor Browser. See the [README](https://github.com/legenki/tortuga#readme) for what it does and doesn't do.

## Install the helper

The helper is the small program that runs Tor and downloads torrents. Pick the file for your system below.

| System | File | How |
|---|---|---|
| **macOS** (Apple silicon and Intel) | `Tortuga-Helper-{{VERSION}}-macos.pkg` | Open it and follow the installer. |
| **Debian, Ubuntu** (x86-64) | `tortuga-helper_{{VERSION}}_amd64.deb` | `sudo apt install ./tortuga-helper_{{VERSION}}_amd64.deb` |
| **Debian, Ubuntu** (ARM64) | `tortuga-helper_{{VERSION}}_arm64.deb` | `sudo apt install ./tortuga-helper_{{VERSION}}_arm64.deb` |
| **Windows** (x86-64) | `Tortuga-Helper-{{VERSION}}-windows-x86_64.zip` | Unzip, then run `powershell -ExecutionPolicy Bypass -File install.ps1` in that folder. No admin rights needed. |

If macOS won't open the installer because it can't check the developer, open **System Settings → Privacy & Security** and choose **Open Anyway**.

## The extension

`tortuga-chrome-{{VERSION}}.zip` and `tortuga-firefox-{{VERSION}}.zip` are the packages sent to the Chrome Web Store and Firefox Add-ons. Install the extension from the stores once it's listed there; store reviews can take a few days after a release. `tortuga-firefox-{{VERSION}}-source.zip` is the source for Mozilla's reviewers.

## Good to know

- **Torrents don't go through Tor.** They download from your own IP, and other people in the swarm can see it.
- **In Chrome, only Incognito windows go through Tor**, on one shared circuit. Firefox sends the whole browser, with a separate circuit for each site.
