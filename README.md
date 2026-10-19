<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Linkway icon">
</p>

<h1 align="center">Linkway</h1>

<p align="center">
  Every link you click, opened in the right browser, profile or app.
</p>

<p align="center">
  <a href="https://github.com/0-LY/linkway/releases/latest/download/Linkway.zip"><b>Download Linkway for macOS</b></a>
  ·
  <a href="https://github.com/0-LY/linkway/releases">All releases</a>
</p>

<p align="center">
  <img src="docs/screenshots/picker.png" width="420" alt="The Linkway picker">
</p>

## What it does

Set Linkway as your default browser. Every link you click — in mail, chat, documents or the terminal —
opens a small picker right where you are, and you choose where it opens.

- Pick with a click, the arrow keys and ↩, the numbers 1–9, or each app's letter.
  ⇧ opens in the background, ⌘C copies the link, esc cancels.
- Recommends the app a link belongs to — a Figma link selects Figma — but only from apps in your list.
- Remembers the app you used last for each site and selects it next time.
- Chrome-family and Firefox profiles show up as separate choices.
- Add, remove, reorder, rename and hide apps, set shortcut letters, picker size and position.

<p align="center">
  <img src="docs/screenshots/apps.png" width="300" alt="Apps settings">
  <img src="docs/screenshots/general.png" width="300" alt="General settings">
</p>

## Install

1. [Download Linkway.zip](https://github.com/0-LY/linkway/releases/latest/download/Linkway.zip) and unzip it.
2. Move **Linkway.app** to your **Applications** folder.
3. Open it. Linkway isn't notarized by Apple, so the first time macOS says it can't check it:
   click **Done**, open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   You only do this once — updates open normally.
4. In Linkway's settings click **Make Default** and confirm.
5. Optional: to list browser profiles separately, allow **Full Disk Access**
   (System Settings → Privacy & Security → Full Disk Access). Linkway only reads the browsers' profile lists.

Requirements: macOS 26 or later on Apple silicon.

## Privacy

- Linkway makes no network connections of its own, apart from checking for updates.
- No account, no analytics, no tracking.
- It only opens normal `http` and `https` links; anything else is ignored.
- Per-site history stores only the site name (for example `example.com`) and the app you picked — never full links.
- Settings and history live in `~/.config/linkway/`, readable only by you.
- With Full Disk Access, Linkway reads only Chrome's and Firefox's profile lists — never cookies, history or passwords.
- Update checks fetch `https://github.com/0-LY/linkway/releases/latest/download/appcast.xml`. No system profile is sent.

## Updates

Linkway updates itself. Every update is signed, and Linkway refuses any download whose signature doesn't match the key built into the app.

In **Settings → General** you can turn off automatic checks or automatic installs, check now, or switch on
**Get beta updates** to try new features early.

## Build from source

```sh
git clone https://github.com/0-LY/linkway.git
cd linkway
./build.sh                # installs to ~/Applications
./build.sh /Applications  # or another folder
```

You need the Xcode Command Line Tools (`xcode-select --install`). The first build downloads Sparkle
(pinned version, checked against its SHA-256).

| Path | Purpose |
|---|---|
| `Sources/main.swift` | App, link handling, picker window |
| `Sources/Picker.swift` | The picker |
| `Sources/Catalog.swift` | Apps, profiles, recommendations, history |
| `Sources/Settings.swift` | Settings window |
| `Sources/Updates.swift` | Automatic updates (Sparkle) |
| `Sources/Identity.swift` | Name, bundle ID and settings folder, read from the built app |
| `identity.env` | Public identity: name, publisher, GitHub owner and repo |
| `Tools/` | App icon |
| `scripts/` | Build, release and Sparkle download scripts |

## Rename or rebrand

Everything public — app name, bundle ID, publisher, GitHub owner and repo, update feed and settings folder — comes from `identity.env`.

1. Edit `identity.env`.
2. Run `scripts/rename.sh`. It regenerates this README, `LICENSE` and `SECURITY.md` from `templates/`, then rebuilds and reinstalls the app and copies your settings to the new folder.
3. Before the first release, create the signing certificate once with `scripts/make-cert.sh`.

Rename only before the first public release. Afterwards, changing `BUNDLE_ID`, `GITHUB_OWNER` or `GITHUB_REPO` cuts installed copies off from updates.

An uncommitted `identity.local.env` can override any value for builds on your own Mac. Releases ignore it.

## Credits

Updates: [Sparkle](https://sparkle-project.org) (MIT).

## License

[MIT](LICENSE) © 0-LY
