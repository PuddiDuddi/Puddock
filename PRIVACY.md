# Privacy Policy — Puddock

*Last updated: 2026-10-31*

Puddock (the Windows app and the "Puddock for Twitch" browser extension) does **not collect, sell, or transmit any personal data** to its developers or to any third party.

## What is processed, and where

| Data | Where it stays | Purpose |
| --- | --- | --- |
| Channel names you open, recent / favourite channels | `%APPDATA%\Puddock\settings.ini` on your PC | Launcher history and favourites |
| Settings (quality, chat layout, …) | `%APPDATA%\Puddock\settings.ini`; the extension reads/writes them through the local app | Shared preferences |
| Twitch login token (optional) | Windows Credential Manager on your PC (entry `Puddock/twitch-auth-token`). While a stream starts it is handed to streamlink through a private in-memory pipe — never written to a file or a command line | Sent **only to Twitch** (to validate it, and by streamlink when requesting the stream) so you get the playback you're entitled to (e.g. ad-free with Turbo / subscriptions) |
| Stream logs | `%TEMP%\puddock-<channel>.log` (token removed) | Troubleshooting |

## Browser extension permissions

- **nativeMessaging** — talk to the Puddock app installed on your computer.
- **contextMenus** — "Watch in Puddock" on Twitch links.
- **activeTab, scripting** — only when you click the toolbar icon, press Alt+M or use the right-click menu: read that one tab's address to know the channel, and pause Twitch's own player there.
- **storage** — remember whether you turned on the ▶ button.
- **Content scripts on two twitch.tv addresses only** — the popout chat (`/popout/*/chat`, to dock it next to the video) and the link the app opens for *Connect in browser* (`/?puddock=connect-…`).
- **Access to all of https://www.twitch.tv/ (optional)** — requested only if you turn on the ▶ button on channel pages, or for the moment of connecting your account (then given back).
- **cookies (optional)** — requested only when you click *Connect Twitch account*, together with twitch.tv access, and removed right after. Reads only the `auth-token` cookie of twitch.tv and passes it to the local app. It is never sent anywhere else.

## No tracking

No analytics, advertising, crash reporting, or remote code. The only network service involved is Twitch itself (and winget/Microsoft if you choose to install dependencies with it).

## Your control

Disconnect the account any time in the app (*Account → Log out*) or the extension's options. Uninstalling removes the app's browser registration and the saved Twitch token; delete `%APPDATA%\Puddock` to remove the remaining settings and channel history.

## Contact

Questions: open an issue at https://github.com/puddiduddi/Puddock
