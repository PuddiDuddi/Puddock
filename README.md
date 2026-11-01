# Puddock

**Low-latency Twitch streams in mpv, with *your own* browser chat docked next to the video — in one seamless window.** Windows only.

Puddock plays the stream through [streamlink](https://streamlink.github.io/) + [mpv](https://mpv.io/) and embeds Twitch's popout chat from the browser you already use, so 7TV, BTTV, FFZ and the rest of your chat extensions and settings just work.

> Puddock is an independent project and is not affiliated with or endorsed by Twitch Interactive, Inc. "for Twitch" is used descriptively only.

<!-- TODO: screenshots (player with chat, toolbar, launcher) -->

## Features

- One window: mpv video + popout chat from your own browser profile, separated by a draggable 1 px divider (chat left or right, resizable).
- One click from the browser: toolbar button / **Alt+M** on any Twitch channel, right-click "Watch in Puddock" on Twitch links, or (opt-in, in the extension's options) a small ▶ button on channel pages.
- Slide-down toolbar at the top edge of the video (**F3**): back to live, chat, swap side, chat settings, fullscreen, on top, video mode.
- Rewind buffer: keep the last 5 / 15 / 30 minutes in memory and seek back in the live stream; **F6** jumps back to live.
- Low-latency mode (streamlink + mpv), quality presets with automatic fallback.
- Optional Twitch account connection for ad-free playback with Turbo / subscriptions — token kept in Windows Credential Manager, never shown, never on a command line, never leaves your PC except to Twitch.
- Shared settings: change them in the app or in the extension's options page.
- One player at a time: opening another channel replaces the current one.

## Install

### Installer (recommended)
1. Download `Puddock-Setup-<version>.exe` from [Releases](https://github.com/puddiduddi/Puddock/releases) and verify it against `SHA256SUMS.txt`.
2. Run it (per-user install, no administrator rights needed).
3. The **Setup** screen opens: it checks for streamlink and mpv and, with your consent, installs missing ones through winget.

### Browser extension
Puddock is distributed on GitHub only (not in the browser stores), so you load the extension yourself:

1. Open `chrome://extensions` (Brave, Edge, Opera and Vivaldi use their own address, e.g. `edge://extensions`; the same page).
2. Turn on **Developer mode**.
3. Click **Load unpacked** and choose `%LOCALAPPDATA%\Programs\Puddock\extension` (the installer puts it there; Setup → *Get it* opens the folder). Without the installer: unzip `puddock-chromium-<version>.zip` from Releases into a folder you keep.

Keep the folder: the browser loads the extension from it every time. After updating Puddock, click the reload icon on the extension card.

**Firefox** (experimental): release Firefox only accepts signed add-ons, so `puddock-firefox-<version>.zip` can only be loaded temporarily (`about:debugging` → *This Firefox* → *Load Temporary Add-on*, until the browser restarts), or permanently in Firefox Developer Edition / Nightly with `xpinstall.signatures.required` set to `false`.

The extension talks to the app through the browser's **Native Messaging** — run `puddock.exe --install` (the installer does this) so the browser can find the app.

## First run

`puddock.exe --setup` (also opened by the installer) shows:
- **streamlink** / **mpv** — found (path + version) or an *Install with winget* button. You can also point to existing executables.
- **Browser connection** — registers Puddock as a native messaging host for Chrome, Chromium, Edge, Brave, Vivaldi and Firefox (per user, `HKCU`).
- **Extension** — *Get it* opens the extension folder and copies `chrome://extensions` for *Load unpacked*; shows whether the extension has contacted the app.
- **Account** (optional) — click *Connect Twitch account* in the extension's options.

## Usage

Open a channel from the extension, or type a channel name / Twitch link in the launcher.

| Key | Action |
| --- | --- |
| F2 | Menu (also: tray icon, right-click the divider) |
| F3 | Toolbar (also: rest the mouse on the handle at the top of the video) |
| F5 | Reload chat |
| F6 | Back to live (reconnect the stream) |
| F8 | Always on top |
| F9 | Show / hide chat |
| F10 | Twitch chat settings |
| F11 / Esc | Fullscreen / leave fullscreen |
| Ctrl+Shift+F12 | Copy video diagnostics |

Inside the video, mpv's own controls work as usual (click the video first): space, ←/→ 5 s, ↑/↓ 1 min within the rewind buffer, 9/0 volume, m mute.

Command line: `puddock.exe [<channel> | --watch <channel> | --setup | --settings | --install | --uninstall | --cmd <channel>]`.
`--cmd` prints the exact streamlink command (without your token) for testing in a terminal.

Settings live in `%APPDATA%\Puddock\settings.ini`; stream logs in `%TEMP%\puddock-<channel>.log`.

## Build from source

Requirements: Windows, PowerShell 7+, [AutoHotkey v2](https://www.autohotkey.com/) and [Ahk2Exe](https://github.com/AutoHotkey/Ahk2Exe), optionally [Inno Setup 6](https://jrsoftware.org/isinfo.php) for the installer.

```powershell
.\build\build.ps1 -Ahk2Exe "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" `
                  -AhkBase "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
```

Output in `dist\`: `puddock.exe`, the unpacked extension, Chromium and Firefox extension zips, the installer (if Inno Setup is installed) and `SHA256SUMS.txt`. You can also run `app\puddock.ahk` directly with AutoHotkey v2 during development.

The version comes from the git tag: push `vX.Y.Z` and the build stamps `X.Y.Z` into `puddock.exe`, both extension manifests and the installer (the `0.0.0` in the sources is a placeholder; local builds use the latest tag, or `-Version X.Y.Z`). CI (`.github/workflows/build.yml`) builds every push and pull request; a `v*` tag also creates a draft release.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Security](SECURITY.md) · [Privacy policy](PRIVACY.md)
- [Publishing checklist](docs/PUBLISHING.md)

## Troubleshooting

- **"No playable streams found"** — the channel is offline or the name is wrong; check the exact name in the browser address bar.
- **"Failed to load plugin twitch"** in the log — an outdated sideloaded plugin in `%APPDATA%\streamlink\plugins\` overrides the built-in one. Update or delete it (and remove its options from `%APPDATA%\streamlink\config.twitch`).
- **mpv / streamlink not found after installing** — programs started from the browser inherit the browser's environment. Fully restart the browser (including background processes) after changing `PATH`, or set the paths explicitly in Setup.
- **Extension says the app is not installed** — run `puddock.exe --install` again (e.g. after moving the program) and restart the browser.
- Use **Ctrl+Shift+F12** in the player and `puddock.exe --cmd <channel>` when reporting issues.

## License

Puddock's source code is released under the [MIT License](LICENSE).
The released `puddock.exe` embeds the AutoHotkey v2 interpreter, which is GPLv2-licensed; see the notice in [LICENSE](LICENSE). streamlink and mpv are separate programs with their own licenses and are not bundled.
