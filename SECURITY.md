# Security

## Reporting a vulnerability

Please report security issues privately through GitHub: **Security → Advisories → Report a vulnerability** on this repository. Do not open a public issue. We aim to acknowledge reports within 7 days.

## Design summary

| Area | Measure |
| --- | --- |
| Browser ↔ app | **Native Messaging only.** The host manifest (`com.puddock.native`) allows only Puddock's extension IDs (`allowed_origins` / `allowed_extensions`); the app re-checks the caller passed on its command line. There is **no custom URL protocol**, so websites cannot launch the app. |
| Messages | Fixed command set (`hello`, `status`, `watch`, `getSettings`, `setSettings`, `setToken`, `clearToken`, `checkNonce`, `openApp`). The extension is loaded unpacked (GitHub-only distribution); its fixed ID comes from the public `key` in `extension/manifest.json`, so any unpacked extension can claim it. That is why the command set is narrow: no command takes a file path or program, and none returns the token. Unknown commands and settings keys are rejected; every value is type- and range-checked. Channel names must match `^[a-z0-9_]{1,25}$`; tokens must be alphanumeric. |
| Process launch | streamlink is started **directly** with `CreateProcess` (no `cmd.exe`, no shell parsing; its output goes straight into the log file), using **full paths** to streamlink and mpv so nothing is resolved through the current directory. Arguments are built only from validated values and the user's own local settings. |
| Twitch token | Optional. Obtained only after the user clicks *Connect Twitch account* (the `cookies` permission is optional and requested at that moment), verified against `id.twitch.tv`, sent to the app over Native Messaging (never in a URL), stored in **Windows Credential Manager** (generic credential `Puddock/twitch-auth-token`, current user, this PC), **never displayed** (the app's token field is write-only), **never put on a command line or in a file**: streamlink reads it from `@\\.\pipe\puddock-<random>` (argparse's argument-file feature) — a named pipe with a DACL for the current user only, remote clients rejected, first-instance creation (no squatting), and answered only for processes inside streamlink's job object (checked per connection); the pipe closes once streamlink has listed the streams, after 30 s at most. Masked in logs, error dialogs and clipboard copies; removed from Credential Manager on uninstall. |
| Network | The app contacts only Twitch (`id.twitch.tv` for token validation; streamlink for the stream). No telemetry, no update pings, no remote code. |
| Dependencies | streamlink and mpv are installed by winget, which verifies installer hashes. Nothing is downloaded by custom code. |
| Install | Per-user install, no administrator rights; registry writes are limited to `HKCU`. |
| Processes | streamlink (and the mpv it starts) run in a job object with kill-on-close: they end with Puddock and are never addressed by a bare PID. Programs are found in installer locations before PATH; shared folders other accounts can write to (e.g. `ProgramData`) are not searched; system tools are called by full path and the working directory is the app's own. |
| Web pages | Links that make the extension act (`?puddock=connect-…`, popout `?puddock=…`) carry one-time nonces issued by the app and verified with it (`checkNonce`); the ▶ button only reacts to real clicks (`isTrusted`) and watch requests are rate-limited. The extension has no standing host access: content scripts run only on the popout chat and the nonce-carrying connect link; the clicked tab is reached through `activeTab`; access to all of twitch.tv (`optional_host_permissions`) is asked for only for the opt-in ▶ button or for the moment of connecting the account, together with the optional `cookies`, and given back afterwards. |
| Releases | Built by GitHub Actions (pinned runner image) from tagged sources (the tag sets the version), with hash-verified AutoHotkey / Ahk2Exe / Inno Setup; the extension packages contain an explicit file allow-list only; `puddock.exe` is signed before it is packed and the installer/uninstaller are signed by Inno Setup (when signing is configured); a build-provenance attestation is attached; publishing needs approval in a protected `release` environment. |

## Accepted residual risks

- **Same-user malware.** Credential Manager (DPAPI underneath) protects the token from other Windows users, other machines and offline disk access — not from a program running as you, which could read it there or from streamlink's memory (and the browser's cookies anyway). No local app can fully prevent that.
- **The token pipe's few seconds.** While streamlink starts (30 s at most), the named pipe answers with the token to processes inside streamlink's job object. Code that runs as you could in principle inject into streamlink in that window — the same-user case above.
- **Install location.** Keep Puddock and `%APPDATA%\Puddock` writable only by your user. Anyone who can modify the program or its settings can make it run other executables (e.g. a different streamlink path).
- **Embedded browser window.** The chat is your real browser window, re-parented into Puddock; it has the same privileges it always has.
