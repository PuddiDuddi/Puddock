# Publishing checklist

Written for a publisher who is not the author. Do the steps in order; tick them off in the release PR.

## 0. Before anything
- [ ] **Twitch brand check.** Read the current Twitch brand / trademark guidelines. The product name is *Puddock*; "for Twitch" may appear only descriptively (store title "Puddock for Twitch"). Do not use Twitch logos or the Glitch in icons, screenshots or promo images. If the guidelines forbid "for Twitch" in titles, use "Puddock" and mention Twitch only in the description.
- [ ] **Verify the mpv winget ID.** Run `winget search mpv` and `winget show --id <id> -e`; make sure the ID constant in `app/puddock.ahk` points to the plain mpv build (e.g. shinchiro's), not mpv.net. Update the constant if needed.
- [ ] Verify `Streamlink.Streamlink` with `winget show --id Streamlink.Streamlink -e`.
- [x] Repository: https://github.com/puddiduddi/Puddock (README, privacy policy, installer, winget metadata).
- [ ] Set the version in `build/version.txt` **and** `extension/manifest.json` (they must match).

## 1. Accounts
- Chrome Web Store developer account (one-time 5 USD fee, 2-step verification required).
- addons.mozilla.org (AMO) account (free).
- Microsoft Edge Add-ons: later (Partner Center, free). Edge users can install from the Chrome Web Store meanwhile.
- GitHub repository with Releases and private vulnerability reporting enabled (Settings → Security).

## 2. Build
- Every push / PR → GitHub Actions (`build.yml`) builds and lints everything (artifact `dist`); tag `vX.Y.Z` → also a draft release; or locally: `.\build\build.ps1 -Ahk2Exe … -AhkBase …`.
- Artifacts: `puddock.exe`, `Puddock-Setup-X.Y.Z.exe`, `puddock-chromium-X.Y.Z.zip`, `puddock-firefox-X.Y.Z.zip`, `SHA256SUMS.txt`.

## 3. Chrome Web Store
1. Upload `puddock-chromium-X.Y.Z.zip` (it has no `key` field; the store assigns the ID).
2. **Copy the assigned extension ID** into `CHROMIUM_IDS` at the top of `app/puddock.ahk`, bump the patch version, rebuild and re-release the app. Without this the store extension cannot talk to a compiled app (release builds don't trust the dev ID; for testing a compiled build with the unpacked extension, set `[Developer] AllowDevExtension=1` in `%APPDATA%\Puddock\settings.ini` and re-register in Setup).
3. Listing:
   - **Title:** Puddock for Twitch
   - **Short description (≤132 chars):** Watch Twitch in mpv with your own browser's popout chat docked beside it — one click, one window. Requires the Puddock app.
   - **Long description:**
     > Puddock opens the Twitch channel you're on in mpv (via streamlink) and docks Twitch's popout chat — from your own browser, with 7TV/BTTV/FFZ and all your settings — right next to the video in a single window.
     > • One click: toolbar button, Alt+M, or right-click a Twitch link
     > • Low-latency playback, quality presets, rewind buffer, back-to-live
     > • Slide-down toolbar, fullscreen, always-on-top, chat left/right
     > • Settings shared between the extension and the app
     > Requires the free Puddock app for Windows (open source): https://github.com/puddiduddi/Puddock
     > Puddock is not affiliated with Twitch.
   - **Category:** Entertainment (or Tools). **Language:** English.
   - **Single purpose:** "Open the current Twitch channel in the locally installed Puddock player (mpv) and dock the user's Twitch popout chat next to it."
   - **Permission justifications:**
     - `nativeMessaging`: communicate with the locally installed Puddock app to start playback and share settings.
     - `contextMenus`: offer "Watch in Puddock" on Twitch links.
     - `activeTab` + `scripting`: when the user clicks the toolbar icon / presses Alt+M / uses the context menu, read that tab's URL to know the channel and pause Twitch's own player in it.
     - `storage`: remember whether the user enabled the optional ▶ button.
     - Content scripts (only `https://www.twitch.tv/popout/*/chat*` and `https://www.twitch.tv/?puddock=connect-*`): dock the popout chat next to the player; react to the app's one-time connect link.
     - Optional host `https://www.twitch.tv/*`: only if the user turns on the ▶ button on channel pages (registered dynamically), or during "Connect Twitch account" (removed right after).
     - `cookies` (optional, requested on demand): when the user clicks "Connect Twitch account", read only twitch.tv's `auth-token` cookie and pass it to the local app so streams play with the user's entitlements (e.g. ad-free with Turbo). It is never sent to any server other than Twitch.
     - Remote code: **No.** Data usage: **does not collect user data** (tick the certifications).
   - **Privacy policy URL:** link to `PRIVACY.md` on GitHub (or GitHub Pages).
   - **Assets:** icon 128×128 (`extension/icons/128.png`), at least 1 screenshot 1280×800 (or 640×400), small promo tile 440×280. No Twitch logos.
4. Submit; expect review questions about `cookies` — point to the justification and that it is optional.

## 4. Firefox (AMO)
1. Upload `puddock-firefox-X.Y.Z.zip`, choose "On this site" listing.
2. **Source code submission:** the extension has no minified/generated code, but the manifest is transformed by `build/build.ps1`. Upload the repository source zip and state: "Built with build/build.ps1 (PowerShell) from extension/; the script only rewrites manifest.json (removes `key`, uses background.scripts, adds browser_specific_settings)."
3. Mark chat docking in Firefox as experimental in the listing.
4. The gecko ID is `puddock@puddock.app`; it is already in the app's Firefox host manifest.
5. Run `web-ext lint` on `puddock-firefox-X.Y.Z.zip` and check the generated `browser_specific_settings.gecko.data_collection_permissions` (`{"required":["none"]}`) against AMO's current requirements.
6. Check on a fresh Firefox profile that the two static content scripts (popout chat, connect link) run right after install: in Firefox MV3 the user controls site access, so the options page may need to ask for `https://www.twitch.tv/popout/*` explicitly. Also confirm `optional_host_permissions` is accepted.

## 5. Code signing (recommended before public release)
- Free for open source: **SignPath Foundation** (apply with the GitHub repo; signing runs in CI).
- Paid: **Azure Trusted Signing** (low monthly cost, requires identity validation).
- Wire `build/sign.ps1` to the chosen service (it fails closed until then) and set the repository variable `SIGNING_ENABLED=true`. `build.ps1 -SignScript` signs `puddock.exe` before packing it and has Inno Setup sign the installer and uninstaller; it verifies every signature.
- In GitHub: create the protected environment `release` with required reviewers, a tag protection rule for `v*`. Tool versions and SHA256 are pinned in `build.yml`; update them together when upgrading.

## 6. winget
1. After a signed GitHub release exists: `wingetcreate new <installer URL>` (or fill `packaging/winget/*.yaml` and run `winget validate`).
2. Check `InstallerType: inno`, `Scope: user`, dependency `Streamlink.Streamlink`, SHA256 from `SHA256SUMS.txt`.
3. Open the PR to `microsoft/winget-pkgs` (`wingetcreate submit`).

## 7. Release
- [ ] GitHub release notes, attach artifacts + `SHA256SUMS.txt`.
- [ ] Update README store / winget links.
- [ ] Smoke test on a clean Windows user: installer → Setup (winget installs) → extension from store → watch a live channel → connect account → uninstall leaves no `HKCU\…\NativeMessagingHosts\com.puddock.native` keys.
