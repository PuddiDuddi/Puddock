#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
; next to THIS file — not A_ScriptDir, which is tests\ when tests\run.ahk includes this script
#Include %A_LineFile%\..\lib\Json.ahk
; The rest of the program: only classes and functions, so the order doesn't matter, and nothing
; in them runs before the entry point below.
#Include %A_LineFile%\..\lib\Player.ahk
#Include %A_LineFile%\..\lib\Launcher.ahk
#Include %A_LineFile%\..\lib\TopBar.ahk
#Include %A_LineFile%\..\lib\Widgets.ahk
#Include %A_LineFile%\..\lib\Config.ahk
#Include %A_LineFile%\..\lib\Process.ahk
#Include %A_LineFile%\..\lib\Tools.ahk
#Include %A_LineFile%\..\lib\Chat.ahk
#Include %A_LineFile%\..\lib\Host.ahk
#Include %A_LineFile%\..\lib\App.ahk
#Include %A_LineFile%\..\lib\Account.ahk
#Include %A_LineFile%\..\lib\Ui.ahk
;@Ahk2Exe-SetMainIcon assets\puddock.ico
;@Ahk2Exe-SetName Puddock
;@Ahk2Exe-SetProductName Puddock
;@Ahk2Exe-SetDescription Puddock - Twitch streams in mpv with your browser's chat
;@Ahk2Exe-SetCopyright Copyright (c) 2026 Puddock contributors (MIT)
;@Ahk2Exe-SetVersion 0.0.0
; ---------------------------------------------------------------------------
;  Puddock — streamlink video (mpv) and your own browser's Twitch popout chat
;  in ONE seamless window.
;
;  Usage:
;    puddock                          -> launcher (channels, settings, account, setup)
;    puddock <channel|url>            -> watch a channel right away (same as --watch)
;    puddock --watch <ch> [--chat-nonce <hex>]  -> what the browser extension asks for
;    puddock --setup | --settings     -> launcher on that tab
;    puddock --cmd <channel>          -> show + copy the streamlink command, for terminal tests
;    puddock --install | --uninstall  -> register / remove the browser connection (per user)
;  Started by a browser as its native messaging host, it answers the extension instead
;  (see NativeHost) and shows no window.
;
;  Player hotkeys (while the window is active):
;    F11 - fullscreen     Esc - leave fullscreen
;    F9  - show/hide chat F8  - always on top
;    F10 - Twitch chat settings   F5 - reload chat   F2 - menu (also tray / right-click the divider)
;    F6  - back to live (reconnects the stream)   Ctrl+Shift+F12 - copy video diagnostics
;    F3  - toolbar (also: rest the mouse on the small handle at the top of the video)
;    In mpv itself (click the video): ←/→ 5 s, ↑/↓ 1 min back/forward within the Rewind buffer.
;    Drag the divider between video and chat to resize the chat.
;
;  Settings: %APPDATA%\Puddock\settings.ini. The Twitch auth token is kept in Windows Credential
;  Manager, is never shown in the UI and never appears on a command line.
; ---------------------------------------------------------------------------

APP       := "Puddock"
VERSION   := "0.0.0"                                   ; stamped by build/build.ps1 from the git tag
DATA_DIR  := EnvGet("APPDATA") "\Puddock"
INI_FILE  := DATA_DIR "\settings.ini"
WEB_CLIENT_ID := "kimne78kx3ncx6brgo4mv6wki5h1ko"     ; twitch.tv's own client id (what streamlink needs)
CRED_TARGET   := "Puddock/twitch-auth-token"          ; Windows Credential Manager entry for the token

; ----- browser connection (native messaging) -----
; Only these extensions may talk to the app. Puddock is distributed through GitHub only: users load
; the extension unpacked, and the public "key" in extension/manifest.json fixes its ID. That key is
; public, so any unpacked extension can claim this ID — which is why the host accepts only a fixed,
; validated command set (no paths, no token read-back). Add store IDs here if it is ever listed.
NATIVE_HOST   := "com.puddock.native"
PORT_TITLE    := "puddock-port-"                      ; + chat nonce: hidden window of the helper behind the extension's port
HOST_PORT     := false                                ; host mode: this helper serves such a port
HOST_OUT      := 0                                    ; host mode: stdout, the way to the extension
CHROMIUM_IDS  := ["lblgbbefjfbhcecckfkacpoeikbfggif"]
GECKO_ID      := "puddock@puddock.app"
STORE_URL     := ""                                   ; Chrome Web Store page, once published
HOST_REG_KEYS := ["Google\Chrome", "Chromium", "Microsoft\Edge", "BraveSoftware\Brave-Browser", "Vivaldi"]
LEGACY_PROTO  := "HKCU\Software\Classes\twitchmpv"    ; removed: any web page could trigger it

; ----- dependencies (installed with the user's consent through winget, which verifies hashes) -----
STREAMLINK_WINGET := "Streamlink.Streamlink"
MPV_WINGET        := "shinchiro.mpv"                  ; VERIFY before release (docs/PUBLISHING.md)

; Twitch dark palette
T := { bg: "0E0E10", panel: "18181B", input: "1F1F23", hover: "2C2C33", line: "2F2F35"
     , text: "F2F2F4", muted: "CBCBD3", dim: "A2A2AE", accent: "9146FF", accentHi: "A970FF"
     , section: "C4A3FF", ok: "2EE68A", warn: "FFC24D" }

FONT := "Consolas"
ICON := A_ScriptDir "\assets\puddock.ico"
EXT_DIR := DirExist(A_ScriptDir "\extension") ? A_ScriptDir "\extension" : A_ScriptDir "\..\extension"

DEFAULTS := Map(
    "Quality",          "best",
    "LowLatency",       1,
    "Rewind",           5,
    "VideoMode",        "Embedded",
    "TopBar",           1,
    "MpvArgs",          "--keep-open=no",
    "StreamlinkArgs",   "",
    "StreamlinkPath",   "",
    "MpvPath",          "",
    "BrowserPath",      "",
    "ChatWidth",        340,
    "ChatSide",         "Right",
    "ChatDark",         1,
    "ChatInFullscreen", 0,
    "WinW",             1620,
    "WinH",             720,
    "RememberPos",      1,
    "StartFullscreen",  0,
    "AlwaysOnTop",      0,
    "CloseLauncher",    0)

; ---------- entry point ------------------------------------------------------
P := 0      ; Player instance (player mode)
L := 0      ; Launcher instance (launcher mode)
HOST_MODE := IsNativeHostLaunch()
OnError(Crash)
SetWorkingDir(A_ScriptDir)             ; never resolve a program from whatever folder we were started in
SetTitleMatchMode("RegEx")             ; every window-title match below is an (anchored) regex
if HOST_MODE {
    NativeHost()                       ; never returns
}
A_IconHidden := false                 ; hidden only while acting as the browser's helper
if !A_IsCompiled && FileExist(ICON)
    TraySetIcon(ICON)                  ; also becomes the icon of every Gui window
DarkMenus()
PrepareDataDir()
ScrubStaleLogs()

arg := A_Args.Length ? A_Args[1] : ""
switch arg {
    case "--install":
        RegisterNativeHost()
        ExitApp
    case "--uninstall":
        UnregisterNativeHost()
        ClearToken()                   ; uninstalling must not leave the Twitch session behind
        ExitApp
    case "--cmd":
        ch := ParseChannel(A_Args.Length > 1 ? A_Args[2] : "")
        if (ch = "") {
            MsgBox("Usage: puddock --cmd <channel>", APP, "Iconi")
            ExitApp
        }
        A_Clipboard := cmd := StreamlinkCmd(LoadConfig(), ch) " --loglevel debug"
        MsgBox("Copied to the clipboard — paste it into a terminal:`n`n" cmd
             . (LoadToken() != "" ? "`n`n(Your Twitch login is left out on purpose.)" : ""), APP, "Iconi")
        ExitApp
    case "", "--settings", "--setup":
        if !LockLauncher()
            ExitApp
        firstRun := MissingTools(LoadConfig()) != "" || !NativeHostRegistered()
        L := Launcher(arg = "--settings" ? "Settings" : arg = "--setup" || firstRun ? "Setup" : "Watch")
    default:
        ; "--watch <channel> [--chat-nonce <hex>]" or just "<channel|url>"
        ch := ParseChannel(arg = "--watch" ? (A_Args.Length > 1 ? A_Args[2] : "") : arg)
        nonce := ""
        if (arg = "--watch" && A_Args.Length > 3 && A_Args[3] = "--chat-nonce" && RegExMatch(A_Args[4], "^[a-f0-9]{16,64}$"))
            nonce := A_Args[4]
        if (ch = "") {
            MsgBox("Not a valid Twitch channel: " (arg = "--watch" && A_Args.Length > 1 ? A_Args[2] : arg), APP, "Iconx")
            ExitApp
        }
        if !LockPlayer(ch)
            ExitApp
        P := Player(ch, nonce)
}

; ---------- hotkeys ------------------------------------------------------------
#HotIf P && P.IsActive()
F11::P.ToggleFullscreen()
F9::P.ToggleChat()
F8::P.ToggleOnTop()
F2::P.ShowMenu()
F5::P.ReloadChat()
F10::P.ChatSettings()
F6::P.ReloadStream()
^+F12::P.Diagnose()
F3::P.bar.Toggle()
#HotIf P && P.isFull && P.IsActive()
Esc::P.ToggleFullscreen()
#HotIf L && WinActive("ahk_id " L.g.Hwnd)
Enter::L.OnEnter()
NumpadEnter::L.OnEnter()
#HotIf

