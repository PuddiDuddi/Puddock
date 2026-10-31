#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include %A_ScriptDir%\lib\Json.ahk
;@Ahk2Exe-SetMainIcon assets\puddock.ico
;@Ahk2Exe-SetName Puddock
;@Ahk2Exe-SetProductName Puddock
;@Ahk2Exe-SetDescription Puddock - Twitch streams in mpv with your browser's chat
;@Ahk2Exe-SetCopyright Copyright (c) 2026 Puddock contributors (MIT)
;@Ahk2Exe-SetVersion 0.1.0
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
VERSION   := "0.1.0"
DATA_DIR  := EnvGet("APPDATA") "\Puddock"
INI_FILE  := DATA_DIR "\settings.ini"
WEB_CLIENT_ID := "kimne78kx3ncx6brgo4mv6wki5h1ko"     ; twitch.tv's own client id (what streamlink needs)
CRED_TARGET   := "Puddock/twitch-auth-token"          ; Windows Credential Manager entry for the token

; ----- browser connection (native messaging) -----
; Only these extensions may talk to the app: add the Chrome Web Store ID here after the first
; upload. The dev build's ID (fixed by the public "key" in extension/manifest.json, so anyone can
; load an unpacked copy with it) is trusted only from source, or with [Developer]
; AllowDevExtension=1 in settings.ini (then Setup → Re-register). See AllowedChromiumIds().
NATIVE_HOST   := "com.puddock.native"
CHROMIUM_IDS  := []
DEV_EXT_ID    := "lblgbbefjfbhcecckfkacpoeikbfggif"
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
#HotIf P && P.MouseOverVideo()
~LButton::P.FocusVideo()          ; embedded mode: click on the video -> keyboard goes to mpv
#HotIf P && P.isFull && P.IsActive()
Esc::P.ToggleFullscreen()
#HotIf L && WinActive("ahk_id " L.g.Hwnd)
Enter::L.OnEnter()
NumpadEnter::L.OnEnter()
#HotIf

; ===========================================================================
;  Player: one window = mpv panel + divider + the user's own browser chat window
; ===========================================================================
class Player {
    __New(channel, chatNonce := "") {
        ; Per-monitor DPI aware like mpv and the browser, so all three agree on pixel sizes
        ; (otherwise mpv can leave an unpainted strip at the right/bottom on scaled displays).
        try DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")     ; PER_MONITOR_AWARE_V2
        this.ch := channel, this.chatNonce := chatNonce
        cfg := this.cfg := LoadConfig()
        this.right := cfg["ChatSide"] != "Left"
        this.chatHwnd := 0, this.chatVisible := true, this.chatBeforeFull := true
        this.isFull := false, this.wasMax := false, this.saved := [], this.inset := [0, 0, 0, 0]
        this.slPid := 0, this.videoUp := false, this.tickFn := 0, this.chatFn := 0, this.mpvHwnd := 0
        this.secret := 0, this.proc := 0
        this.mpvTitle := "puddock-video-" DllCall("GetCurrentProcessId")       ; finds our mpv window
        this.embedded := false
        this.reloading := false

        ; everything in physical pixels, so it matches MoveWindow / mpv / the browser
        g := this.g := Gui("+Resize -DPIScale +MinSize640x360", channel " · " APP)
        g.BackColor := T.bg
        g.OnEvent("Size", (gui, mm, w, h) => this.Layout(mm, w, h))
        g.OnEvent("Close", (*) => ExitApp())
        if cfg["AlwaysOnTop"]
            g.Opt("+AlwaysOnTop")
        DarkTitle(g.Hwnd)
        this.SetScale((DllCall("GetDpiForWindow", "Ptr", g.Hwnd, "UInt") || A_ScreenDPI) / 96)

        vg := this.vg := Gui("-Caption -DPIScale +Parent" g.Hwnd)   ; mpv renders into this
        vg.BackColor := "000000"
        vg.SetFont("s14 c" T.dim, FONT)
        this.lbl := vg.AddText("x0 y0 w10 h10 Center +0x200", "Connecting to " channel "…")

        ; divider: a 1px line inside a slightly wider (black) grab area
        this.sp := Gui("-Caption -DPIScale +Parent" g.Hwnd)
        this.sp.BackColor := "000000"
        this.spLine := this.sp.AddText("x0 y0 w1 h1 Background" T.line)

        ; The browser's chat lives in here, shifted so its own title bar and frame fall outside
        ; (clipped): nothing to grab, the chat just fills the panel.
        this.host := Gui("-Caption -DPIScale +Parent" g.Hwnd)
        this.host.BackColor := T.panel

        OnMessage(0x20,  ObjBindMethod(this, "OnSetCursor"))    ; WM_SETCURSOR
        OnMessage(0x201, ObjBindMethod(this, "OnSplitDrag"))    ; WM_LBUTTONDOWN
        OnMessage(0x205, ObjBindMethod(this, "OnSplitMenu"))    ; WM_RBUTTONUP
        OnMessage(0x2E0, ObjBindMethod(this, "OnDpiChanged"))   ; WM_DPICHANGED
        OnMessage(0x3,   ObjBindMethod(this, "OnMove"))         ; WM_MOVE -> drag mpv along
        OnMessage(0x6,   ObjBindMethod(this, "OnActivate"))     ; WM_ACTIVATE (embedded mode focus)
        ; keep our title bar "active" while mpv (a separate window) has the focus
        this.fgCb := CallbackCreate(ObjBindMethod(this, "OnForeground"), , 7)
        this.fgHook := DllCall("SetWinEventHook", "UInt", 3, "UInt", 3, "Ptr", 0, "Ptr", this.fgCb
                             , "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")    ; EVENT_SYSTEM_FOREGROUND
        OnExit((*) => this.Cleanup())
        this.BuildMenus()

        g.Show(this.InitialPos())
        vg.Show("x0 y0 w10 h10 NA")
        this.sp.Show("x0 y0 w1 h1 NA Hide")
        this.host.Show("x0 y0 w1 h1 NA Hide")
        this.Relayout()
        this.bar := TopBar(this)

        this.StartStream()
        this.StartChat()
        AddRecent(channel)
        if cfg["StartFullscreen"]
            this.ToggleFullscreen()
    }

    InitialPos() {
        cfg := this.cfg, w := cfg["WinW"], h := cfg["WinH"], pos := ""
        if cfg["RememberPos"] {
            x  := IniRead(INI_FILE, "State", "X", ""), y  := IniRead(INI_FILE, "State", "Y", "")
            sw := IniRead(INI_FILE, "State", "W", ""), sh := IniRead(INI_FILE, "State", "H", "")
            if IsInteger(x) && IsInteger(y) && OnScreen(x + 60, y + 20)
                pos := "x" x " y" y " "
            if IsInteger(sw) && IsInteger(sh)
                w := sw, h := sh
        }
        return pos "w" w " h" h
    }

    ; ---------- streamlink -> mpv embedded in the video panel ----------
    StartStream() {
        if (missing := MissingTools(this.cfg)) != "" {
            if MsgBox(missing "`n`nOpen Setup now?", APP, "YesNo Iconx Owner" this.g.Hwnd) = "Yes"
                Run(SelfCmd("--setup"))
            ExitApp
        }
        this.embedded := this.cfg["VideoMode"] = "Embedded"
        this.secret := 0
        if (token := LoadToken()) != "" {
            try this.secret := SecretPipe("twitch-api-header=Authorization=OAuth " token "`n")
            catch
                TrayTip("Couldn't hand your Twitch login to streamlink safely — playing without it.", APP)
        }
        this.secretAt := A_TickCount
        cmd := StreamlinkCmd(this.cfg, this.ch, this.embedded ? this.vg.Hwnd : this.mpvTitle, this.secret ? this.secret.name : "")
        ; started directly (no cmd.exe in between), stdout + stderr captured into the log
        this.log := A_Temp "\puddock-" this.ch ".log"
        try this.proc := ChildProcess(cmd, this.log)
        catch as e {
            this.FeedSecret(true)
            MsgBox("Couldn't start streamlink: " MaskToken(e.Message " " e.Extra), APP, "Iconx Owner" this.g.Hwnd)
            ExitApp
        }
        this.slPid := this.proc.pid
        this.tickFn := ObjBindMethod(this, "Tick")
        SetTimer(this.tickFn, 100)
    }

    ; Answer streamlink's reads of the token pipe while it starts; close the pipe once it has
    ; listed the streams (the Twitch plugin's options are applied before that), or after 30 s.
    FeedSecret(force := false) {
        if !this.secret
            return
        if !force {
            this.secret.Serve(this.proc)
            if (A_TickCount - this.secretAt < 30000 && this.proc.Running) {
                try log := FileRead(this.log)
                catch
                    return
                if !InStr(log, "Available streams") && !InStr(log, "Opening stream")
                    return
            }
        }
        this.secret.Close()
        this.secret := 0
    }

    Tick() {
        this.FeedSecret()
        if !this.videoUp {
            if this.embedded && (h := DllCall("FindWindowEx", "Ptr", this.vg.Hwnd, "Ptr", 0, "Str", "mpv", "Ptr", 0, "Ptr"))
                             && this.proc.Owns(WindowPid(h)) {
                this.videoUp := true, this.mpvHwnd := h
                this.lbl.Visible := false
                if WinActive(this.g.Hwnd)
                    this.FocusVideo()
            } else if !this.embedded && (h := WinExist("^" this.mpvTitle "$ ahk_class ^mpv$"))
                             && this.proc.Owns(WindowPid(h))     ; only the mpv that our streamlink started
                this.AttachVideo(h)
        }
        this.GuardVideo()
        if this.chatHwnd && !DllCall("IsWindow", "Ptr", this.chatHwnd) {    ; browser closed / crashed
            this.chatHwnd := 0
            this.Relayout()
            this.UpdateMenus()
        }
        if !this.proc.Running {
            SetTimer(this.tickFn, 0)
            if !this.videoUp
                this.ReportFailure()
            ExitApp
        }
    }

    ReportFailure() {
        out := ""
        ScrubLog(this.log)
        try out := Trim(FileRead(this.log), " `r`n")
        ; a sideloaded plugin (e.g. an ad-block twitch.py in %APPDATA%\streamlink\plugins) that no longer
        ; matches the installed streamlink: it gets skipped silently, so say so explicitly
        plugin := ""
        if RegExMatch(out, "Failed to load plugin (\w+)", &m) {
            plugin := "`n`nNote: your custom streamlink plugin “" m[1] "” failed to load and was skipped"
            if RegExMatch(out, 'File "([^"]*\\streamlink\\plugins\\[^"]+\.py)"', &f)
                plugin .= ":`n" f[1]
            plugin .= "`nIt's outdated for your streamlink version — update it, or rename/remove it."
        }
        if InStr(out, "No playable streams found") {
            this.lbl.Text := this.ch " is offline"
            return MsgBox(this.ch " is offline (or the channel doesn't exist)." plugin, APP
                        , (plugin = "" ? "Iconi T8" : "Icon!") " Owner" this.g.Hwnd)
        }
        this.lbl.Text := "streamlink failed"
        lines := StrSplit(out, "`n", "`r")
        tail := ""
        Loop Min(lines.Length, 12)
            tail .= lines[lines.Length - Min(lines.Length, 12) + A_Index] "`n"
        msg := "streamlink stopped before the video started.`n`n" (tail != "" ? tail : "(no output)`n")
        if (InStr(out, "401") || InStr(out, "Unauthorized")) && LoadToken() != ""
            msg .= "`nYour Twitch login looks expired — renew it in the Account tab.`n"
        msg .= plugin "`n`nTo test in a terminal: puddock --cmd " this.ch "`nFull log: " this.log
        MsgBox(msg, APP, "Iconx Owner" this.g.Hwnd)
    }

    ; ---------- chat: the user's OWN browser (their 7TV / BTTV / settings apply), glued in ----------
    ; With the extension: a Twitch popout tab carrying a one-time nonce is turned into a popup
    ; window by the extension, which also writes "puddock:<nonce>:<insets>" into its title so we
    ; can find exactly that window. Without it: a Chromium browser in --app mode.
    StartChat() {
        if (this.chatNonce != "")                        ; the extension already opened it
            return this.WaitForMarkedChat(this.chatNonce, false)
        if ExtensionSeenRecently() {
            nonce := RandomHex(16)
            RememberNonce("Chat", nonce)
            try {
                Run(ChatUrl(this.ch, this.cfg["ChatDark"], nonce))   ; default browser
                return this.WaitForMarkedChat(nonce, true)
            }
        }
        this.StartAppChat()
    }

    WaitForMarkedChat(nonce, canFallBack) {
        this.chatMarker := "puddock:" nonce, this.chatFallBack := canFallBack
        this.chatT0 := A_TickCount
        this.chatFn := ObjBindMethod(this, "FindMarkedChat")
        SetTimer(this.chatFn, 150)
    }

    FindMarkedChat() {
        static browsers := ["brave.exe", "chrome.exe", "msedge.exe", "vivaldi.exe", "opera.exe", "chromium.exe", "firefox.exe"]
        for h in WinGetList("^" this.chatMarker ":") {
            try {
                cls := WinGetClass(h), exe := StrLower(WinGetProcessName(h))
            } catch
                continue
            if (cls = "Chrome_WidgetWin_1" || cls = "MozillaWindowClass") && HasVal(browsers, exe)
                return this.Embed(h)
        }
        if (A_TickCount - this.chatT0 < 15000)
            return
        SetTimer(this.chatFn, 0)
        if this.chatFallBack                             ; extension not in the default browser?
            this.StartAppChat()
        else
            this.ChatFail("The browser didn't open the chat window. Playing video only.")
    }

    StartAppChat() {
        browser := FindChromium(this.cfg["BrowserPath"])
        if (browser = "")
            return this.ChatFail("No Chromium-based browser found for the chat. Playing video only.")
        SplitPath(browser, &exe)
        this.browserExe := exe
        this.before := WinGetList("ahk_exe " exe)
        try Run(Format('"{1}" --app={2}', browser, ChatUrl(this.ch, this.cfg["ChatDark"])))
        catch
            return this.ChatFail("Couldn't start the browser for the chat. Playing video only.")
        this.chatT0 := A_TickCount, this.firstSeen := 0
        this.chatFn := ObjBindMethod(this, "FindChat")
        SetTimer(this.chatFn, 150)
    }

    FindChat() {
        ; A NEW window of the browser we just started whose title looks like the chat. (Never just
        ; "any new window": that could be one the user opened, which we'd swallow and later close.)
        for h in WinGetList("ahk_exe ^" RegExReplace(this.browserExe, "\.", "\.") "$") {
            if HasVal(this.before, h)
                continue
            try {
                if WinGetClass(h) != "Chrome_WidgetWin_1" || (title := WinGetTitle(h)) = ""
                    continue
            } catch
                continue
            if InStr(title, this.ch) || InStr(title, "chat")
                return this.Embed(h)
        }
        if A_TickCount - this.chatT0 > 15000
            this.ChatFail("Couldn't catch the browser's chat window. Playing video only.")
    }

    Embed(h) {
        SetTimer(this.chatFn, 0)
        WinSetStyle("-0xC40000",   h)      ; no caption / frame
        WinSetStyle("-0x80000000", h)      ; -WS_POPUP
        WinSetStyle("+0x40000000", h)      ; +WS_CHILD (drops off the taskbar)
        DllCall("SetParent", "Ptr", h, "Ptr", this.host.Hwnd)
        this.chatHwnd := h
        this.Relayout()
        this.UpdateMenus()
        ; the browser re-lays out its frame a moment after the style change: measure again
        for ms in [300, 1000, 3000]
            SetTimer(ObjBindMethod(this, "Relayout"), -ms)
    }

    ChatFail(msg) {
        if this.chatFn
            SetTimer(this.chatFn, 0)
        this.chatVisible := false
        TrayTip(msg, APP)
    }

    ; ---------- layout ----------
    SetScale(scale) {
        this.scale  := scale
        this.chatPx := Round(this.cfg["ChatWidth"] * scale)
        this.splitW := Max(3, Round(4 * scale))          ; grab area
        this.lineW  := Max(1, Round(scale))              ; visible line
    }

    Layout(mm, w, h) {
        if (mm = -1)                       ; minimized
            return
        on := this.chatVisible && this.chatHwnd
        cw := on ? Max(0, Min(this.chatPx, w - Round(240 * this.scale))) : 0
        sw := cw ? this.splitW : 0
        vw := w - cw - sw
        MoveWin(this.vg.Hwnd, this.right ? 0 : cw + sw, 0, vw, h)
        this.lbl.Move(0, h // 2 - 40, vw, 80)

        DllCall("ShowWindow", "Ptr", this.host.Hwnd, "Int", cw ? 8 : 0)    ; SW_SHOWNA / SW_HIDE
        if cw {
            MoveWin(this.host.Hwnd, this.right ? w - cw : 0, 0, cw, h)
            i := this.ChatInsets()          ; browser title bar + borders, pushed outside the panel
            MoveWin(this.chatHwnd, -i[1], -i[2], cw + i[1] + i[3], h + i[2] + i[4])
        }
        DllCall("ShowWindow", "Ptr", this.sp.Hwnd, "Int", sw ? 8 : 0)
        if sw {
            MoveWin(this.sp.Hwnd, this.right ? vw : cw, 0, sw, h)
            this.spLine.Move(this.right ? sw - this.lineW : 0, 0, this.lineW, h)   ; line hugs the chat
        }
        this.SyncVideo()
    }

    ; [left, top, right, bottom] distance from the browser window's edges to the web page inside.
    ; Chromium: measured from its page child window. Firefox has none: the extension writes
    ; the numbers into the window title ("puddock:<nonce>:<top>:<left>:<right>:<bottom>").
    ChatInsets() {
        ins := ""
        if (page := FindDescendant(this.chatHwnd, "Chrome_RenderWidgetHostHWND")) {
            w := WinRect(this.chatHwnd), c := WinRect(page)
            if (c[3] > c[1] && c[4] > c[2])
                ins := [c[1] - w[1], c[2] - w[2], w[3] - c[3], w[4] - c[4]]
        } else if RegExMatch(WindowText(this.chatHwnd), "puddock:[a-f0-9]+:(\d+):(\d+):(\d+):(\d+)", &m)
            ins := [Integer(m[2]), Integer(m[1]), Integer(m[3]), Integer(m[4])]
        if IsObject(ins) {
            ok := true
            for v in ins
                ok := ok && v >= 0 && v < 300 * this.scale
            if ok
                this.inset := ins
        }
        return this.inset
    }

    Relayout(*) {
        this.g.GetClientPos(, , &w, &h)
        this.Layout(WinGetMinMax(this.g.Hwnd), w, h)
    }

    OnDpiChanged(wParam, lParam, msg, hwnd) {
        if (hwnd != this.g.Hwnd)
            return
        this.SetScale((wParam & 0xFFFF) / 96)
        if !this.isFull {                     ; take Windows' suggested size for the new monitor
            x := NumGet(lParam, 0, "Int"), y := NumGet(lParam, 4, "Int")
            w := NumGet(lParam, 8, "Int") - x, h := NumGet(lParam, 12, "Int") - y
            DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", x, "Int", y, "Int", w, "Int", h, "UInt", 0x14)  ; NOZORDER|NOACTIVATE
        }
        this.Relayout()
        return 0
    }

    ; mpv runs as its own borderless window (embedding it with --wid cut it off from mouse and
    ; keyboard input). Make it part of our window: owned by it (stays on top of it, minimizes
    ; with it), no taskbar / Alt+Tab entry, and kept exactly over the video area.
    AttachVideo(h) {
        this.mpvHwnd := h, this.videoUp := true, this.attachedAt := A_TickCount
        DllCall("ShowWindow", "Ptr", h, "Int", 0)
        ex := DllCall("GetWindowLongPtr", "Ptr", h, "Int", -20, "Ptr")
        DllCall("SetWindowLongPtr", "Ptr", h, "Int", -20, "Ptr", (ex | 0x80) & ~0x40000)   ; +TOOLWINDOW -APPWINDOW
        DllCall("SetWindowLongPtr", "Ptr", h, "Int", -8, "Ptr", this.g.Hwnd)               ; owner = our window
        if DllCall("GetWindowLongPtr", "Ptr", this.g.Hwnd, "Int", -20, "Ptr") & 0x8       ; we're always-on-top
            DllCall("SetWindowPos", "Ptr", h, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)
        if WinGetMinMax(this.g.Hwnd) != -1 {
            r := WinRect(this.vg.Hwnd)              ; un-minimize straight into place, without a flash
            wp := Buffer(44, 0)
            NumPut("UInt", 44, wp, 0), NumPut("UInt", 4, wp, 8)                  ; SW_SHOWNOACTIVATE
            NumPut("Int", r[1], "Int", r[2], "Int", r[3], "Int", r[4], wp, 28)   ; rcNormalPosition
            DllCall("SetWindowPlacement", "Ptr", h, "Ptr", wp)
        }
        this.lbl.Visible := false
        this.SyncVideo()
    }

    SyncVideo(*) {
        if this.embedded || !this.mpvHwnd || !DllCall("IsWindow", "Ptr", this.mpvHwnd) || WinGetMinMax(this.g.Hwnd) = -1
            return
        if !DllCall("IsWindowVisible", "Ptr", this.mpvHwnd) || DllCall("IsIconic", "Ptr", this.mpvHwnd)
            DllCall("ShowWindow", "Ptr", this.mpvHwnd, "Int", 4)                 ; SW_SHOWNOACTIVATE
        r := WinRect(this.vg.Hwnd)
        DllCall("SetWindowPos", "Ptr", this.mpvHwnd, "Ptr", 0, "Int", r[1], "Int", r[2]
              , "Int", r[3] - r[1], "Int", r[4] - r[2], "UInt", 0x214)           ; NOZORDER|NOACTIVATE|NOOWNERZORDER
    }

    ; mpv is a real window, so Win+Down / Win+Up can still minimize or maximize it on its own.
    ; Minimizing it minimizes the whole player; maximizing just snaps it back into place.
    GuardVideo() {
        if this.embedded
            return this.GuardEmbedded()
        if !this.mpvHwnd || WinGetMinMax(this.g.Hwnd) = -1 || !DllCall("IsWindow", "Ptr", this.mpvHwnd)
            return
        if DllCall("IsIconic", "Ptr", this.mpvHwnd) {
            if (A_TickCount - this.attachedAt < 3000)   ; mpv starts minimized on purpose: just place it
                this.SyncVideo()
            else
                WinMinimize(this.g.Hwnd)
        }
        else if DllCall("IsZoomed", "Ptr", this.mpvHwnd) {
            DllCall("ShowWindow", "Ptr", this.mpvHwnd, "Int", 4)       ; SW_SHOWNOACTIVATE = restore
            this.SyncVideo()
        }
    }

    ; Embedded with --wid, mpv creates its window DISABLED (WS_DISABLED): no mouse or keyboard at
    ; all, clicks fall through to us. Turn it back on and keep it on. That also re-enables things
    ; mpv uses the disabled state to avoid (dragging / fullscreen moving the child around), so
    ; dragging is off on the command line and the window is snapped back if it moves anyway.
    GuardEmbedded() {
        if !this.mpvHwnd || !DllCall("IsWindow", "Ptr", this.mpvHwnd)
            return
        if !DllCall("IsWindowEnabled", "Ptr", this.mpvHwnd)
            DllCall("EnableWindow", "Ptr", this.mpvHwnd, "Int", true)
        v := WinRect(this.vg.Hwnd), m := WinRect(this.mpvHwnd)
        if (m[1] != v[1] || m[2] != v[2] || m[3] != v[3] || m[4] != v[4])
            MoveWin(this.mpvHwnd, 0, 0, v[3] - v[1], v[4] - v[2])
    }

    OnMove(wParam, lParam, msg, hwnd) {
        if (hwnd = this.g.Hwnd)
            this.SyncVideo()
    }

    IsActive() => WinActive(this.g.Hwnd) || this.mpvHwnd && WinActive(this.mpvHwnd)

    ; Embedded mode: mpv is a child window of another process, so keyboard focus doesn't follow
    ; clicks on it by itself. Hand it over on click / when we get activated with the mouse over it.
    FocusVideo() {
        if this.embedded && this.mpvHwnd && DllCall("IsWindow", "Ptr", this.mpvHwnd)
            try ControlFocus(this.mpvHwnd)
    }

    MouseOverVideo() {
        if !this.embedded || !this.mpvHwnd
            return false
        MouseGetPos(, , &win, &ctl, 2)
        return win = this.g.Hwnd && (ctl = this.mpvHwnd || ctl = this.vg.Hwnd)
    }

    OnActivate(wParam, lParam, msg, hwnd) {
        if (hwnd = this.g.Hwnd && (wParam & 0xFFFF) && this.MouseOverVideo())
            SetTimer(ObjBindMethod(this, "FocusVideo"), -30)
    }

    SetVideoMode(mode) {
        if (mode = this.cfg["VideoMode"])
            return
        this.cfg["VideoMode"] := mode
        IniWrite(mode, INI_FILE, "Settings", "VideoMode")
        this.UpdateMenus()
        this.ReloadStream()                           ; picks the new mode up in StartStream
    }

    ; What's under the mouse vs. where mpv is: copied to the clipboard, to debug embedded input.
    Diagnose() {
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        under := DllCall("WindowFromPoint", "Int64", (my << 32) | (mx & 0xFFFFFFFF), "Ptr")
        ctx := DllCall("GetThreadDpiAwarenessContext", "Ptr")
        out := "Mode: " (this.embedded ? "Embedded (--wid)" : "Separate window") "`n"
             . "Mouse (screen): " mx ", " my "`n"
             . "Our thread DPI awareness: " DllCall("GetAwarenessFromDpiAwarenessContext", "Ptr", ctx, "Int") "`n`n"
             . "Under mouse: " DescribeWin(under) "`n"
             . "mpv:         " DescribeWin(this.mpvHwnd) "`n"
             . "Video area:  " DescribeWin(this.vg.Hwnd) "`n"
             . "Main window: " DescribeWin(this.g.Hwnd) "`n"
             . "Focus window (thread of foreground): " DescribeWin(FocusOfForeground()) "`n"
             . "Foreground: " DescribeWin(DllCall("GetForegroundWindow", "Ptr")) "`n"
             . "Toolbar: " (this.HasOwnProp("bar") ? this.bar.Describe() : "(none)")
        A_Clipboard := out
        MsgBox(out "`n`n(Copied to the clipboard.)", APP " — video diagnostics", "Iconi Owner" this.g.Hwnd)
    }

    OnForeground(hook, event, hwnd, *) {
        if (hwnd = this.mpvHwnd)
            DllCall("SendMessage", "Ptr", this.g.Hwnd, "UInt", 0x86, "Ptr", 1, "Ptr", 0)  ; WM_NCACTIVATE: look active
        else if (hwnd != this.g.Hwnd && this.mpvHwnd)
            DllCall("SendMessage", "Ptr", this.g.Hwnd, "UInt", 0x86, "Ptr", 0, "Ptr", 0)
    }

    OnSetCursor(wParam, *) {
        if (wParam != this.sp.Hwnd)
            return
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32644, "Ptr"))   ; IDC_SIZEWE
        return 1
    }

    OnSplitDrag(wParam, lParam, msg, hwnd) {
        if (hwnd != this.sp.Hwnd)
            return
        this.spLine.Opt("+Background" T.accent), this.spLine.Redraw()
        pt := Buffer(8)
        while GetKeyState("LButton", "P") {
            DllCall("GetCursorPos", "Ptr", pt)
            DllCall("ScreenToClient", "Ptr", this.g.Hwnd, "Ptr", pt)
            x := NumGet(pt, 0, "Int")
            this.g.GetClientPos(, , &w, &h)
            cw := this.right ? w - x - this.splitW // 2 : x - this.splitW // 2
            cw := Max(Round(200 * this.scale), Min(cw, w - Round(320 * this.scale)))
            if (cw != this.chatPx) {
                this.chatPx := cw
                this.Layout(0, w, h)
            }
            Sleep(10)
        }
        this.spLine.Opt("+Background" T.line), this.spLine.Redraw()
        this.cfg["ChatWidth"] := Round(this.chatPx / this.scale)
        IniWrite(this.cfg["ChatWidth"], INI_FILE, "Settings", "ChatWidth")
        return 0
    }

    OnSplitMenu(wParam, lParam, msg, hwnd) {
        if (hwnd != this.sp.Hwnd)
            return
        this.ShowMenu()
        return 0
    }

    ; ---------- menus (tray, right-click on the divider, F2) ----------
    BuildMenus() {
        cm := this.chatMenu := Menu()
        cm.Add("Show chat`tF9", (*) => this.ToggleChat())
        cm.Add("Chat on the left", (*) => this.SetSide("Left"))
        cm.Add("Chat on the right", (*) => this.SetSide("Right"))
        cm.Add()
        cm.Add("Twitch chat settings…`tF10", (*) => this.ChatSettings())
        cm.Add("Reload chat`tF5", (*) => this.ReloadChat())
        cm.Add()
        cm.Add("Zoom in", (*) => this.ChatZoom("in"))
        cm.Add("Zoom out", (*) => this.ChatZoom("out"))
        cm.Add("Reset zoom", (*) => this.ChatZoom("reset"))

        vm := this.videoMenu := Menu()
        vm.Add("Embedded (recommended)", (*) => this.SetVideoMode("Embedded"))
        vm.Add("Separate window (fallback)", (*) => this.SetVideoMode("Window"))
        vm.Add()
        vm.Add("Toolbar at the top edge", (*) => this.ToggleTopBar())
        vm.Add("Copy diagnostics`tCtrl+Shift+F12", (*) => this.Diagnose())

        this.menu := Menu()
        this.FillMainMenu(this.menu)

        ; tray: "show" on top, then exactly the same menu as F2 / right-click
        tray := A_TrayMenu
        tray.Delete()
        tray.Add("Show " this.ch, (*) => BringToFront(this.g.Hwnd))
        tray.Default := "Show " this.ch
        tray.Add()
        this.FillMainMenu(tray)
        tray.ClickCount := 1
        A_IconTip := this.ch " · " APP
        this.UpdateMenus()
    }

    ; stream -> view -> submenus -> app -> exit
    FillMainMenu(m) {
        m.Add("Back to live (reload stream)`tF6", (*) => this.ReloadStream())
        m.Add("Fullscreen`tF11", (*) => this.ToggleFullscreen())
        m.Add("Always on top`tF8", (*) => this.ToggleOnTop())
        m.Add()
        m.Add("Chat", this.chatMenu)
        m.Add("Video", this.videoMenu)
        m.Add()
        m.Add("Open channel in browser", (*) => this.OpenInBrowser())
        m.Add("Launcher…", (*) => Run(SelfCmd("")))
        m.Add("Settings…", (*) => Run(SelfCmd("--settings")))
        m.Add()
        m.Add("Exit", (*) => ExitApp())
    }

    UpdateMenus() {
        cm := this.chatMenu
        for item in ["Show chat`tF9", "Twitch chat settings…`tF10", "Zoom in", "Zoom out", "Reset zoom", "Reload chat`tF5"]
            MenuEnable(cm, item, this.chatHwnd)
        MenuCheck(cm, "Show chat`tF9", this.chatHwnd && this.chatVisible)
        MenuCheck(cm, "Chat on the left", !this.right)
        MenuCheck(cm, "Chat on the right", this.right)
        MenuCheck(this.videoMenu, "Embedded (recommended)", this.cfg["VideoMode"] = "Embedded")
        MenuCheck(this.videoMenu, "Separate window (fallback)", this.cfg["VideoMode"] != "Embedded")
        MenuCheck(this.videoMenu, "Toolbar at the top edge", this.cfg["TopBar"])
        onTop := DllCall("GetWindowLongPtr", "Ptr", this.g.Hwnd, "Int", -20, "Ptr") & 0x8    ; WS_EX_TOPMOST
        for m in [this.menu, A_TrayMenu] {
            MenuCheck(m, "Fullscreen`tF11", this.isFull)
            MenuCheck(m, "Always on top`tF8", onTop)
        }
        if this.HasOwnProp("bar")
            this.bar.Refresh()
    }

    ToggleTopBar() {
        this.cfg["TopBar"] := !this.cfg["TopBar"]
        IniWrite(this.cfg["TopBar"] ? 1 : 0, INI_FILE, "Settings", "TopBar")
        this.UpdateMenus()
    }

    ShowMenu() {
        this.UpdateMenus()
        this.menu.Show()
    }

    ; ---------- actions ----------
    ToggleChat() {
        if !this.chatHwnd
            return
        this.chatVisible := !this.chatVisible
        this.Relayout()
        this.UpdateMenus()
    }

    ToggleOnTop() {
        WinSetAlwaysOnTop(-1, this.g.Hwnd)
        this.UpdateMenus()
    }

    SetSide(side) {
        this.right := side != "Left"
        this.cfg["ChatSide"] := side
        IniWrite(side, INI_FILE, "Settings", "ChatSide")
        this.Relayout()
        this.UpdateMenus()
    }

    ; Keys go to the chat as real keystrokes: focus it inside our window, then Send.
    ; A Text control reports Click on mouse DOWN (STN_CLICKED), so the toolbar calls this while
    ; the button is still held and captured by the bar: keys sent then don't open anything in the
    ; chat. Wait until the mouse is released, outside the click handler.
    ChatKeys(keys) {
        if !this.chatHwnd
            return
        if GetKeyState("LButton", "P") || GetKeyState("RButton", "P") {
            SetTimer(() => this.ChatKeys(keys), -30)
            return
        }
        if !this.chatVisible
            this.ToggleChat()
        WinActivate(this.g.Hwnd)
        try ControlFocus(this.chatHwnd)
        Sleep(50)
        Send(keys)
    }

    ; handled by the extension inside the chat (chat.js): settings gear / page zoom
    ChatSettings() => this.ChatKeys("!+s")
    ChatZoom(dir) => this.ChatKeys(dir = "in" ? "!+{Up}" : dir = "out" ? "!+{Down}" : "!+0")
    ReloadChat() => this.ChatKeys("{F5}")

    ; Reconnect streamlink + mpv in place: jumps back to the live edge, and fixes a stuck stream.
    ReloadStream() {
        if this.reloading
            return
        this.reloading := true
        SetTimer(this.tickFn, 0)                      ; so the old streamlink exiting doesn't close us
        if this.proc
            this.proc.Kill()                          ; streamlink + mpv (the whole job)
        this.FeedSecret(true)
        this.slPid := 0, this.videoUp := false, this.mpvHwnd := 0
        this.lbl.Text := "Reconnecting to " this.ch "…"
        this.lbl.Visible := true
        this.StartStream()
        this.reloading := false
    }

    OpenInBrowser() => Run("https://www.twitch.tv/" this.ch)

    ToggleFullscreen() {
        g := this.g
        if !this.isFull {
            this.wasMax := WinGetMinMax(g.Hwnd) = 1
            if this.wasMax
                WinRestore(g.Hwnd)
            WinGetPos(&x, &y, &w, &h, g.Hwnd)
            this.saved := [x, y, w, h]
            this.chatBeforeFull := this.chatVisible
            if !this.cfg["ChatInFullscreen"]
                this.chatVisible := false
            MonitorRect(x + w // 2, y + h // 2, &ml, &mt, &mr, &mb)
            g.Opt("-Caption -Resize")
            WinMove(ml, mt, mr - ml, mb - mt, g.Hwnd)
            this.isFull := true
        } else {
            g.Opt("+Caption +Resize")
            this.chatVisible := this.chatBeforeFull
            s := this.saved
            WinMove(s[1], s[2], s[3], s[4], g.Hwnd)
            if this.wasMax
                WinMaximize(g.Hwnd)
            this.isFull := false
        }
        this.Relayout()
        this.UpdateMenus()
    }

    Cleanup() {
        if this.HasOwnProp("fgHook") && this.fgHook
            DllCall("UnhookWinEvent", "Ptr", this.fgHook)
        if this.tickFn
            SetTimer(this.tickFn, 0)
        if this.chatFn
            SetTimer(this.chatFn, 0)
        if this.cfg["RememberPos"] && !this.isFull && WinExist(this.g.Hwnd) && WinGetMinMax(this.g.Hwnd) = 0 {
            WinGetPos(&x, &y, , , this.g.Hwnd)
            this.g.GetClientPos(, , &w, &h)
            for k, v in Map("X", x, "Y", y, "W", w, "H", h)
                IniWrite(v, INI_FILE, "State", k)
        }
        if this.chatHwnd && DllCall("IsWindow", "Ptr", this.chatHwnd) {
            DllCall("ShowWindow", "Ptr", this.chatHwnd, "Int", 0)
            DllCall("SetParent", "Ptr", this.chatHwnd, "Ptr", 0)
            try WinSetStyle("-0x40000000", this.chatHwnd)
            DllCall("PostMessage", "Ptr", this.chatHwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0)   ; WM_CLOSE
        }
        if this.HasOwnProp("proc") && this.proc
            this.proc.Kill()                          ; streamlink + mpv (the job also dies with us)
        if this.HasOwnProp("secret")
            this.FeedSecret(true)
        if this.HasOwnProp("log")
            ScrubLog(this.log)            ; e.g. --loglevel debug prints every argument, token included
    }
}

; ===========================================================================
;  Launcher: channels, settings, account and setup in one dark window
; ===========================================================================
class Launcher {
    static W := 600, H := 660

    __New(page) {
        this.cfg := LoadConfig()
        this.pages := Map("Watch", [], "Settings", [], "Account", [], "Setup", [])
        this.btns := Map(), this.hot := 0, this.cur := "", this.page := ""
        this.rows := [], this.lastRaw := "", this.flashUntil := 0
        this.hoverFn := ObjBindMethod(this, "HoverCheck")

        g := this.g := Gui("-MaximizeBox", APP)
        g.BackColor := T.bg
        g.MarginX := g.MarginY := 0
        g.SetFont("s10 c" T.text, FONT)
        g.OnEvent("Close", (*) => ExitApp())
        g.OnEvent("Escape", (*) => ExitApp())
        DarkTitle(g.Hwnd)

        this.BuildHeader()
        this.BuildWatch()
        this.BuildSettings()
        this.BuildAccount()
        this.BuildSetup()
        this.cur := ""
        this.footer := g.AddText("x24 y626 w552 h22", "")
        this.footer.SetFont("s9")
        this.footerReady := true
        this.footer.OnEvent("Click", (*) => !this.footerReady && this.ShowPage("Setup"))

        OnMessage(0x200, ObjBindMethod(this, "OnMouseMove"))   ; WM_MOUSEMOVE  -> hover
        OnMessage(0x20,  ObjBindMethod(this, "OnSetCursor"))   ; WM_SETCURSOR  -> hand cursor
        OnMessage(0x6,   ObjBindMethod(this, "OnActivate"))    ; WM_ACTIVATE   -> refresh list

        tray := A_TrayMenu                                         ; plain app menu, nothing AutoHotkey-specific
        tray.Delete()
        tray.Add("Show " APP, (*) => BringToFront(this.g.Hwnd))
        tray.Default := "Show " APP
        tray.Add()
        tray.Add("Settings…", (*) => (BringToFront(this.g.Hwnd), this.ShowPage("Settings")))
        tray.Add()
        tray.Add("Exit", (*) => ExitApp())
        tray.ClickCount := 1
        A_IconTip := APP

        g.Show("w" Launcher.W " h" Launcher.H)
        this.ShowPage(page)
    }

    ; ---------- pages ----------
    BuildHeader() {
        g := this.g
        logoSrc := A_IsCompiled ? A_ScriptFullPath : ICON          ; the app icon (embedded in the exe)
        if FileExist(logoSrc)
            g.AddPicture("x24 y20 w40 h40 Icon1", logoSrc)
        else {
            logo := g.AddText("x24 y20 w40 h40 Center +0x200 cFFFFFF Background" T.accent, "▶")
            logo.SetFont("s14")
            RoundCtl(logo.Hwnd, 10)
        }
        g.AddText("x76 y18 w240 h28", APP).SetFont("s15 bold")
        g.AddText("x76 y46 w256 h18 c" T.muted, "streamlink + mpv + your browser's chat").SetFont("s9")

        this.acctHdr := g.AddText("x340 y26 w236 h20 Right", "")
        this.acctHdr.SetFont("s9")
        this.acctHdr.OnEvent("Click", (*) => this.ShowPage("Account"))

        this.nav := Map(), x := 24
        for i, name in ["Watch", "Settings", "Account", "Setup"] {
            w := [64, 80, 80, 64][i]
            c := g.AddText(Format("x{} y86 w{} h26 Center", x, w), name)
            c.SetFont("s11")
            c.OnEvent("Click", this.ShowPage.Bind(this, name))
            this.nav[name] := {c: c, x: x, w: w}
            x += w + 8
        }
        this.underline := g.AddText("x24 y114 w64 h2 Background" T.accent)
        g.AddText("x0 y117 w" Launcher.W " h1 Background" T.line)
    }

    BuildWatch() {
        this.cur := "Watch"
        this.Caption(24, 140, "CHANNEL")
        this.chan := this.Input(24, 162, 432, "", "channel name or twitch.tv link")
        this.Button(464, 162, 112, 34, "Watch  ▶", (*) => this.Watch(), "accent")

        this.Caption(24, 222, "FAVORITES & RECENT")
        this.Button(384, 212, 94, 28, "★  Favorite", (*) => this.ToggleFav())
        this.Button(486, 212, 90, 28, "✕  Remove", (*) => this.RemoveRow())

        lv := this.lv := this.Add("ListView", "x24 y248 w552 h288 -Hdr -Multi -E0x200 +LV0x10000 c" T.text
                                 . " Background" T.panel, ["Channel", "Last watched"])
        SetWindowTheme(lv.Hwnd, "DarkMode_Explorer")
        RowHeight(lv, 34)
        RoundCtl(lv.Hwnd, 8)
        lv.OnEvent("DoubleClick", (lv, row) => row && this.Launch(this.rows[row]))
        lv.OnEvent("ItemSelect", (lv, row, sel) => sel && this.rows[row] != "" && (this.chan.Value := this.rows[row]))

        this.Hint(24, 546, 552, "Double-click or Enter to watch  ·  F11 fullscreen  ·  F9 chat  ·  F8 on top  ·  drag the divider to resize chat")
        this.Add("Text", "x290 y594 w226 h20 Right c" T.muted, "Close launcher after Watch").SetFont("s9")
        this.closeAfter := Toggle(this, 524, 588, this.cfg["CloseLauncher"]
            , (v) => (this.cfg["CloseLauncher"] := v, IniWrite(v, INI_FILE, "Settings", "CloseLauncher")))
    }

    BuildSettings() {
        this.cur := "Settings"
        this.Button(372, 82, 96, 30, "Defaults", (*) => this.Fill(DEFAULTS))
        this.saveBtn := this.Button(476, 82, 100, 30, "Save", (*) => this.Save(), "accent")
        f := this.f := Map()

        this.Section(134, "PLAYER")
        this.Label(24, 158, "Quality")
        f["Quality"] := Segment(this, 180, 158, 66, ["best", "1080p60", "720p60", "480p", "360p", "audio_only"]
                                              , ["Best", "1080p60", "720p60", "480p", "360p", "Audio"])
        this.Label(24, 198, "Low latency")
        f["LowLatency"] := Toggle(this, 180, 201)
        this.Label(252, 198, "Rewind", 64)
        f["Rewind"] := Segment(this, 320, 198, 64, ["0", "5", "15", "30"], ["Off", "5 min", "15 min", "30 min"])
        this.Label(24, 238, "mpv arguments")
        f["MpvArgs"] := this.Input(180, 238, 396)
        this.Label(24, 278, "Streamlink arguments")
        f["StreamlinkArgs"] := this.Input(180, 278, 396, "", "extra flags, e.g. --hls-live-edge 2")
        this.Label(24, 318, "Video mode")
        f["VideoMode"] := Segment(this, 180, 318, 140, ["Embedded", "Window"], ["Embedded", "Separate window"])

        this.Section(366, "CHAT")
        this.Label(24, 390, "Fallback browser")
        f["BrowserPath"] := this.Input(180, 390, 300, "", "auto: your default Chromium browser")
        this.Button(488, 390, 88, 34, "Browse…", (*) => this.Browse("BrowserPath", "browser"))
        this.Label(24, 430, "Side")
        f["ChatSide"] := Segment(this, 180, 430, 70, ["Left", "Right"], ["Left", "Right"])
        this.Label(360, 430, "Width (px)", 96)
        f["ChatWidth"] := this.Input(456, 430, 120)
        this.Label(24, 470, "Dark theme")
        f["ChatDark"] := Toggle(this, 180, 473)
        this.Label(360, 470, "Keep in fullscreen", 160)
        f["ChatInFullscreen"] := Toggle(this, 524, 473)

        this.Section(518, "WINDOW")
        this.Label(24, 542, "Default size (px)")
        f["WinW"] := this.Input(180, 542, 64)
        this.Add("Text", "x244 y550 w24 h20 Center c" T.dim, "×")
        f["WinH"] := this.Input(268, 542, 64)
        this.Label(360, 542, "Remember position", 160)
        f["RememberPos"] := Toggle(this, 524, 545)
        this.Label(24, 582, "Start fullscreen")
        f["StartFullscreen"] := Toggle(this, 180, 585)
        this.Label(360, 582, "Always on top", 160)
        f["AlwaysOnTop"] := Toggle(this, 524, 585)

        this.Fill(this.cfg)
    }

    BuildAccount() {
        this.cur := "Account"
        this.Section(134, "TWITCH ACCOUNT")
        this.acctTxt := this.Add("Text", "x24 y165 w552 h22", "")
        this.acctTxt.SetFont("bold")
        this.Hint(24, 192, 552, "With a login, streamlink plays ad-free (Turbo or a sub to the channel) and opens sub-only "
                             . "streams. Without one everything still works — with ads.")
        this.Label(24, 236, "New token")
        this.tokenEd := this.Input(180, 236, 396, "", "paste an auth-token to save / replace", "Password")
        this.Button(180, 278, 124, 34, "Save", (*) => this.SaveTokenUI(), "accent")
        this.Button(312, 278, 124, 34, "Test", (*) => this.TestTokenUI())
        this.Button(444, 278, 132, 34, "Log out", (*) => this.LogoutUI())
        this.Hint(180, 320, 396, "Kept in Windows Credential Manager. Write-only: never shown again, never on a command line.")

        this.Section(364, "CONNECT IN YOUR BROWSER  —  ONE CLICK")
        this.Add("Text", "x24 y388 w552 h40 c" T.muted
            , "Be logged in to twitch.tv in your browser, with the Puddock extension (Setup tab). Its options "
            . "open; press “Connect Twitch account” there.")
        this.Button(24, 436, 210, 34, "Connect in browser", (*) => this.ConnectInBrowser(), "accent")
        this.Hint(24, 480, 552, "The extension reads only the twitch.tv login cookie, hands it to this app over the private "
                             . "browser connection, and drops the cookie permission again.")

        this.Section(522, "MANUALLY")
        this.Add("Text", "x24 y546 w552 h40 c" T.muted
            , "twitch.tv in your browser → F12 → Application → Cookies → https://www.twitch.tv → copy the value of "
            . "auth-token and paste it above.")
    }

    UpdateAccount(*) {
        on := LoadToken() != ""
        login := IniRead(INI_FILE, "Account", "Login", ""), checked := IniRead(INI_FILE, "Account", "Checked", "")
        try checked := checked != "" ? " · checked " FormatTime(checked, "yyyy-MM-dd") : ""
        catch
            checked := ""
        this.acctTxt.Text := on ? "●  Logged in as " (login != "" ? login : "(unverified)") checked
                                : "○  Anonymous — streams play with ads"
        this.acctTxt.SetFont("c" (on ? T.ok : T.muted))
        this.acctHdr.Text := on ? "●  " (login != "" ? login : "logged in") : "○  not logged in"
        this.acctHdr.SetFont("c" (on ? T.ok : T.dim))
    }


    ; -> {login, clientId}, 0 when Twitch rejects it, "" when Twitch can't be reached
    CheckToken(tok) {
        try return ValidateToken(tok)
        catch
            return ""
    }

    SaveTokenUI() {
        tok := CleanToken(this.tokenEd.Value)
        if (tok = "")
            return this.Flash(Trim(this.tokenEd.Value) = "" ? "Nothing to save — paste a token first" : "That doesn't look like a Twitch token", T.warn)
        info := this.CheckToken(tok)
        if (info = 0)
            return this.Flash("Twitch rejected this token — log in to twitch.tv again and copy a fresh one", T.warn)
        SaveToken(tok, info ? info.login : "")
        this.tokenEd.Value := ""                      ; write-only: the field never holds a saved token
        this.UpdateAccount()
        if !info
            this.Flash("Saved, but couldn't reach Twitch to verify it", T.warn)
        else if (info.clientId != WEB_CLIENT_ID)
            this.Flash("Saved — but it isn't a twitch.tv browser token, streamlink may ignore it", T.warn)
        else
            this.Flash("Logged in as " info.login, T.ok)
    }

    ; tests what's typed in the field, or else the saved token (without showing it)
    TestTokenUI() {
        typed := CleanToken(this.tokenEd.Value)
        tok := typed != "" ? typed : LoadToken()
        if (tok = "")
            return this.Flash("No token saved or typed", T.warn)
        info := this.CheckToken(tok)
        if (info = "")
            this.Flash("Couldn't reach Twitch", T.warn)
        else if (info = 0)
            this.Flash("Token rejected — it expired or you logged out on twitch.tv", T.warn)
        else {
            if (typed = "")
                IniWrite(info.login, INI_FILE, "Account", "Login"), IniWrite(A_Now, INI_FILE, "Account", "Checked")
            this.UpdateAccount()
            this.Flash("Valid: " info.login ", expires in " (info.expires ? info.expires // 86400 " days" : "never")
                     . (info.clientId != WEB_CLIENT_ID ? " (not a twitch.tv browser token!)" : ""), T.ok)
        }
    }

    LogoutUI() {
        ClearToken()
        this.tokenEd.Value := ""
        this.UpdateAccount()
        this.Flash("Logged out — streams will play anonymously", T.muted)
    }


    ; Setup: everything Puddock needs, each with its state and a way to fix it
    BuildSetup() {
        this.cur := "Setup"
        this.setup := Map()
        rows := [["streamlink", "1 · STREAMLINK", 134], ["mpv", "2 · MPV", 232]]
        for r in rows {
            key := r[1], y := r[3]
            this.Section(y, r[2])
            st := this.Add("Text", Format("x24 y{} w340 h22", y + 31), "")
            st.SetFont("bold")
            inst := this.Button(376, y + 24, 96, 34, "Install", this.InstallTool.Bind(this, key), "accent")
            this.Button(480, y + 24, 96, 34, "Browse…", this.BrowseTool.Bind(this, key))
            hint := this.Add("Text", Format("x24 y{} w552 h20 c{}", y + 64, T.dim), "")
            hint.SetFont("s9")
            this.setup[key] := {status: st, install: inst, hint: hint}
        }

        this.Section(330, "3 · BROWSER EXTENSION")
        this.extTxt := this.Add("Text", "x24 y361 w340 h22", "")
        this.extTxt.SetFont("bold")
        this.Button(376, 354, 96, 34, "Get it", (*) => this.GetExtension(), "accent")
        this.Button(480, 354, 96, 34, "Unpacked…", (*) => this.OpenExtFolder())
        this.Hint(24, 394, 552, "The chat opens in YOUR browser through the extension, so your 7TV / BTTV / settings apply. "
                             . "Chrome, Brave, Edge, Opera, Vivaldi · Firefox (experimental).")

        this.Section(442, "4 · BROWSER CONNECTION")
        this.hostTxt := this.Add("Text", "x24 y473 w340 h22", "")
        this.hostTxt.SetFont("bold")
        this.hostBtn := this.Button(376, 466, 96, 34, "Register", (*) => (RegisterNativeHost(), this.UpdateStatus()), "accent")
        this.Button(480, 466, 96, 34, "Remove", (*) => (UnregisterNativeHost(), this.UpdateStatus()))
        this.Hint(24, 506, 552, "Lets only the Puddock extension talk to this app (native messaging) — no web page can.", 20)

        this.Section(546, "SHORTCUTS")
        desk := this.Button(24, 570, 180, 34, "Desktop shortcut", (*) => (MakeShortcut(A_Desktop), FlashText(desk, "Created  ✓")))
        start := this.Button(212, 570, 180, 34, "Start menu shortcut", (*) => (MakeShortcut(A_Programs), FlashText(start, "Created  ✓")))
    }

    InstallTool(key, *) {
        id := key = "streamlink" ? STREAMLINK_WINGET : MPV_WINGET
        this.Flash("Asking winget for " id "…", T.section)
        if !(pid := WingetInstall(id)) {
            Run(key = "streamlink" ? "https://streamlink.github.io/install.html" : "https://mpv.io/installation/")
            return this.Flash("winget can't install " key " here — opened its download page instead", T.warn)
        }
        this.Flash("Installing " key " with winget — follow the console window", T.section)
        this.installPid := pid
        SetTimer(this.installFn := ObjBindMethod(this, "InstallDone", key), 1000)
    }

    InstallDone(key) {
        if ProcessExist(this.installPid)
            return
        SetTimer(this.installFn, 0)
        this.UpdateStatus()
        found := key = "streamlink" ? FindTools(LoadConfig()).streamlink : FindTools(LoadConfig()).mpv
        this.Flash(found != "" ? key " is ready" : key " still not found — try Browse…", found != "" ? T.ok : T.warn)
    }

    BrowseTool(key, *) {
        this.g.Opt("+OwnDialogs")
        p := FileSelect(1, , "Select " key ".exe", "Programs (*.exe)")
        if (p = "")
            return
        IniWrite(p, INI_FILE, "Settings", key = "streamlink" ? "StreamlinkPath" : "MpvPath")
        this.cfg := LoadConfig()
        this.UpdateStatus()
    }

    GetExtension() {
        if (STORE_URL != "")
            return Run(STORE_URL)
        this.OpenExtFolder()
        A_Clipboard := "chrome://extensions"
        this.Flash("Not in the stores yet: chrome://extensions → Developer mode → Load unpacked → this folder (copied)", T.section)
    }

    ; Opens the extension's options in the user's browser; they press "Connect" there
    ; (the extension asks for cookie access only at that moment).
    ConnectInBrowser() {
        RememberNonce("Connect", nonce := RandomHex(16))       ; the extension checks it with us first
        Run("https://www.twitch.tv/?puddock=connect-" nonce)
        this.Flash("Your browser opens Puddock's options — press “Connect Twitch account”", T.section)
    }


    ShowPage(name, *) {
        ; Rounded controls (window regions) can leave their old pixels behind when hidden,
        ; so swap pages with drawing paused and repaint the whole window once at the end.
        DllCall("SendMessage", "Ptr", this.g.Hwnd, "UInt", 0xB, "Ptr", 0, "Ptr", 0)   ; WM_SETREDRAW off
        for p, list in this.pages
            for c in list
                SetVis(c, p = name)
        for n, o in this.nav
            o.c.SetFont("c" (n = name ? T.text : T.dim))
        n := this.nav[name]
        this.underline.Move(n.x, , n.w)
        DllCall("SendMessage", "Ptr", this.g.Hwnd, "UInt", 0xB, "Ptr", 1, "Ptr", 0)   ; WM_SETREDRAW on
        DllCall("RedrawWindow", "Ptr", this.g.Hwnd, "Ptr", 0, "Ptr", 0
              , "UInt", 0x585)                                 ; INVALIDATE|ERASE|ALLCHILDREN|UPDATENOW|FRAME
        this.page := name
        if (name = "Watch") {
            this.RefreshList(true)
            try this.chan.Focus()
        }
        this.UpdateStatus()
        this.UpdateAccount()
    }

    OnEnter() {
        if (this.page = "Watch")
            this.Watch()
        else if (this.page = "Settings")
            this.Save()
        else if (this.page = "Account")
            this.SaveTokenUI()
    }

    ; ---------- Watch page ----------
    Watch() {
        ch := ParseChannel(this.chan.Value) || this.Selected()
        if (ch = "")
            return this.Flash("Type a channel name or a twitch.tv link first", T.warn)
        this.Launch(ch)
    }

    Launch(ch) {
        if (ch := ParseChannel(ch)) = ""              ; favourites / recents come from the ini: re-check
            return
        AddRecent(ch)
        try Run(SelfCmd(ch))
        catch as e
            return this.Flash("Couldn't start the player: " e.Message, T.warn)
        this.chan.Value := ""
        this.RefreshList()
        this.Flash("Opening " ch "…", T.section)
        if this.cfg["CloseLauncher"]
            ExitApp
    }

    Selected() {
        row := this.lv.GetNext(0)
        return row ? this.rows[row] : ""
    }

    ToggleFav() {
        ch := this.Selected() || ParseChannel(this.chan.Value)
        if (ch = "")
            return this.Flash("Select or type a channel first", T.warn)
        favs := GetList("Favorites")
        if i := IndexOf(favs, ch)
            favs.RemoveAt(i)
        else
            favs.Push(ch)
        SetList("Favorites", favs)
        this.RefreshList(true)
    }

    RemoveRow() {
        ch := this.Selected()
        if (ch = "")
            return this.Flash("Select a channel in the list first", T.warn)
        favs := GetList("Favorites")
        if i := IndexOf(favs, ch)
            favs.RemoveAt(i)
        SetList("Favorites", favs)
        rec := []
        for e in GetList("Recent")
            if StrSplit(e, "/")[1] != ch
                rec.Push(e)
        SetList("Recent", rec)
        this.RefreshList(true)
    }

    RefreshList(force := false) {
        favs := GetList("Favorites"), rec := GetList("Recent")
        raw := Join(favs) "#" Join(rec)
        if (!force && raw = this.lastRaw)
            return
        this.lastRaw := raw
        lv := this.lv, this.rows := [], seen := Map()
        lv.Opt("-Redraw")
        lv.Delete()
        when := Map()
        for e in rec {
            p := StrSplit(e, "/")
            when[p[1]] := p.Length > 1 ? p[2] : ""
        }
        for ch in favs {
            lv.Add(, "  ★   " ch, when.Has(ch) ? Ago(when[ch]) : "")
            this.rows.Push(ch), seen[ch] := 1
        }
        for e in rec {
            ch := StrSplit(e, "/")[1]
            if seen.Has(ch)
                continue
            lv.Add(, "        " ch, Ago(when[ch]))
            this.rows.Push(ch), seen[ch] := 1
        }
        if !this.rows.Length {
            lv.Add(, "        No channels yet — type one above and hit Watch")
            this.rows.Push("")
        }
        lv.ModifyCol(1, 400)
        lv.ModifyCol(2, "130 Right")
        lv.Opt("+Redraw")
    }

    ; ---------- Settings page ----------
    Fill(c) {
        for k, ctl in this.f
            ctl.Value := c[k]
    }

    Save() {
        c := Map()
        for k, ctl in this.f
            c[k] := Trim(ctl.Value)
        for k, lim in Map("ChatWidth", [200, 1200], "WinW", [640, 7680], "WinH", [360, 4320]) {
            if !IsInteger(c[k]) {
                this.ShowPage("Settings")
                return this.Flash("“" k "” must be a whole number", T.warn)
            }
            c[k] := Max(lim[1], Min(lim[2], Integer(c[k])))
            this.f[k].Value := c[k]
        }
        c["CloseLauncher"] := this.cfg["CloseLauncher"]
        SaveConfig(c)
        this.cfg := c
        FlashText(this.saveBtn, "Saved  ✓")
    }

    Browse(key, exe) {
        this.g.Opt("+OwnDialogs")
        p := FileSelect(1, , "Select " exe, "Programs (*.exe)")
        if (p != "")
            this.f[key].Value := p
    }

    ; ---------- Browser page ----------
    UpdateStatus(*) {
        tools := FindTools(LoadConfig())
        for key, row in this.setup {
            path := tools.%key%
            row.status.Text := path != "" ? "●  Installed" : "○  Not found"
            row.status.SetFont("c" (path != "" ? T.ok : T.warn))
            row.hint.Text := path != "" ? path : "Install with winget (asks first), or point to " key ".exe with Browse…"
            row.install.Text := path != "" ? "Reinstall" : "Install"
            this.Paint(row.install, path != "" ? T.input : T.accent, path != "" ? T.hover : T.accentHi, path != "" ? T.text : "FFFFFF")
        }
        ext := ExtensionSeenRecently()
        this.extTxt.Text := ext ? "●  Connected" : "○  Not connected yet"
        this.extTxt.SetFont("c" (ext ? T.ok : T.warn))
        host := NativeHostRegistered()
        this.hostTxt.Text := host ? "●  Registered" : "○  Not registered"
        this.hostTxt.SetFont("c" (host ? T.ok : T.warn))
        this.hostBtn.Text := host ? "Re-register" : "Register"
        this.Paint(this.hostBtn, host ? T.input : T.accent, host ? T.hover : T.accentHi, host ? T.text : "FFFFFF")

        ; footer: the first thing still missing, or "ready"
        missing := tools.streamlink = "" || tools.mpv = "" ? "streamlink / mpv missing"
                 : !host ? "browser connection not registered"
                 : !ext ? "browser extension not connected yet" : ""
        this.footerReady := missing = ""
        if (A_TickCount < this.flashUntil)
            return
        this.footer.Text := missing = "" ? "●  Ready" : "●  " missing " — open Setup"
        this.footer.SetFont("c" (missing = "" ? T.ok : T.warn))
    }

    OpenExtFolder() {
        if DirExist(EXT_DIR)
            Run(ArgQuote(A_WinDir "\explorer.exe") " " ArgQuote(EXT_DIR))
        else
            this.Flash("Extension folder not found: " EXT_DIR, T.warn)
    }


    ; ---------- widgets ----------
    Add(type, opt := "", text := "") {
        c := this.g.Add(type, opt, text)
        this.Track(c)
        return c
    }

    Track(c) {
        if (this.cur != "")
            this.pages[this.cur].Push(c)
    }

    Section(y, text) => this.Add("Text", "x24 y" y " w552 h18 c" T.section, text).SetFont("s9 bold")
    Caption(x, y, text) => this.Add("Text", Format("x{} y{} w300 h18 c{}", x, y, T.muted), text).SetFont("s9 bold")
    Label(x, y, text, w := 150) => this.Add("Text", Format("x{} y{} w{} h20 c{}", x, y + 8, w, T.muted), text)
    Hint(x, y, w, text, h := 36) => this.Add("Text", Format("x{} y{} w{} h{} c{}", x, y, w, h, T.dim), text).SetFont("s9")

    ; Padded, rounded text input: an Edit inside its own small child window.
    Input(x, y, w, text := "", cue := "", opt := "") {
        fr := Gui("-Caption +E0x10000 +Parent" this.g.Hwnd)        ; WS_EX_CONTROLPARENT: Tab works
        fr.BackColor := T.input
        fr.MarginX := fr.MarginY := 0
        fr.SetFont("s10 c" T.text, FONT)
        e := fr.AddEdit(Format("x10 y7 w{} h20 -E0x200 Background{} {}", w - 20, T.input, opt), text)
        SetWindowTheme(e.Hwnd, "DarkMode_CFD")                       ; lighter placeholder (cue) text
        fr.Show(Format("x{} y{} w{} h34 NA", x, y, w))
        RoundCtl(fr.Hwnd, 6)
        if (cue != "")
            SendMessage(0x1501, 1, StrPtr(cue), e)                   ; EM_SETCUEBANNER
        this.Track(fr)
        return e
    }

    ; Flat rounded button made from a Text control (real buttons can't be coloured).
    Button(x, y, w, h, text, cb, kind := "ghost") {
        accent := kind = "accent"
        c := this.Add("Text", Format("x{} y{} w{} h{} Center +0x200", x, y, w, h), text)
        this.btns[c.Hwnd] := {bg: "", hi: ""}
        this.Paint(c, accent ? T.accent : T.input, accent ? T.accentHi : T.hover, accent ? "FFFFFF" : T.text)
        if accent
            c.SetFont("bold")
        c.OnEvent("Click", cb)
        RoundCtl(c.Hwnd, 6)
        return c
    }

    Paint(c, bg, hi, fg := "") {
        b := this.btns[c.Hwnd], b.bg := bg, b.hi := hi
        c.Opt("+Background" (this.hot = c.Hwnd ? hi : bg))
        if (fg != "")
            c.SetFont("c" fg)
        c.Redraw()
    }

    Flash(text, color) {
        this.footer.Text := text
        this.footer.SetFont("c" color)
        this.flashUntil := A_TickCount + 2500
        SetTimer(ObjBindMethod(this, "UpdateStatus"), -2600)
    }

    ; ---------- hover / cursor ----------
    OnMouseMove(wParam, lParam, msg, hwnd) {
        if (hwnd = this.hot)
            return
        this.Unhover()
        if this.btns.Has(hwnd) {
            this.hot := hwnd
            c := GuiCtrlFromHwnd(hwnd)
            c.Opt("+Background" this.btns[hwnd].hi), c.Redraw()
            SetTimer(this.hoverFn, 80)
        }
    }

    HoverCheck() {
        MouseGetPos(, , , &ctl, 2)
        if (ctl != this.hot)
            this.Unhover()
    }

    Unhover() {
        if !this.hot
            return
        h := this.hot, this.hot := 0
        SetTimer(this.hoverFn, 0)
        if c := GuiCtrlFromHwnd(h)
            c.Opt("+Background" this.btns[h].bg), c.Redraw()
    }

    OnSetCursor(wParam, *) {
        if !this.btns.Has(wParam) && !this.navHas(wParam)
            return
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr"))    ; IDC_HAND
        return 1
    }

    navHas(hwnd) {
        for n, o in this.nav
            if (o.c.Hwnd = hwnd)
                return true
        return hwnd = this.acctHdr.Hwnd || hwnd = this.footer.Hwnd && !this.footerReady
    }

    OnActivate(wParam, lParam, msg, hwnd) {
        if (hwnd != this.g.Hwnd || !(wParam & 0xFFFF))
            return
        if (this.page = "Watch")
            this.RefreshList()
        if (this.page = "Setup")
            this.UpdateStatus()                     ; e.g. after installing something
        this.UpdateAccount()                        ; a login may have arrived from the extension
    }
}

; Slide-down toolbar over the top edge of the video. Its own small window owned by the player:
; stays above the video in both modes and never takes the focus (WS_EX_NOACTIVATE), so the
; keyboard stays with mpv / the chat.
class TopBar {
    static ITEMS := [["live", "Back to live"], ["chat", "Chat"], ["side", "Swap side"]
                   , ["chatset", "Chat settings"], ["full", "Fullscreen"], ["top", "On top"]
                   , ["mode", "Mode: Embedded"], ["menu", "Menu"]]

    __New(player) {
        this.pl := player, this.btns := Map(), this.byKey := Map(), this.hot := 0
        this.shown := false, this.sticky := false, this.enterAt := 0, this.leftAt := 0
        sc := player.scale
        g := this.g := Gui("-Caption +ToolWindow -DPIScale +E0x08000000 +Owner" player.g.Hwnd)
        g.BackColor := T.panel
        g.MarginX := g.MarginY := 0
        g.SetFont("s9 c" T.text, FONT)
        pad := Round(6 * sc), bh := Round(28 * sc), gap := Round(4 * sc), x := pad
        for it in TopBar.ITEMS {
            bw := Round((StrLen(it[2]) * 7 + 22) * sc)
            c := g.AddText(Format("x{} y{} w{} h{} Center +0x200 Background{}", x, pad, bw, bh, T.input), it[2])
            c.OnEvent("Click", this.Click.Bind(this, it[1]))
            this.btns[c.Hwnd] := {c: c, on: false}
            this.byKey[it[1]] := c
            RoundCtl(c.Hwnd, 6)
            x += bw + gap
        }
        this.w := x - gap + pad, this.h := bh + 2 * pad
        g.Show(Format("x0 y0 w{} h{} NA Hide", this.w, this.h))
        r := Round(10 * sc)                                   ; square top, rounded bottom corners
        DllCall("SetWindowRgn", "Ptr", g.Hwnd, "Ptr", DllCall("CreateRoundRectRgn", "Int", 0, "Int", -r
              , "Int", this.w + 1, "Int", this.h + 1, "Int", r, "Int", r, "Ptr"), "Int", true)

        ; the always-visible handle: a small translucent pill at the top centre of the video
        hd := this.hd := Gui("-Caption +ToolWindow -DPIScale +E0x08000000 +Owner" player.g.Hwnd)
        hd.BackColor := T.dim
        this.hw := Round(64 * sc), this.hh := Max(4, Round(6 * sc))
        hd.Show(Format("x0 y0 w{} h{} NA Hide", this.hw, this.hh))
        RoundCtl(hd.Hwnd, 6)
        WinSetTransparent(150, hd.Hwnd)
        this.hdShown := false

        OnMessage(0x200, ObjBindMethod(this, "OnMouseMove"))
        this.tickFn := ObjBindMethod(this, "Check")
        SetTimer(this.tickFn, 60)
    }

    ; Is one of the player's windows (main window, mpv, this bar) in the foreground?
    PlayerActive() {
        root := DllCall("GetAncestor", "Ptr", DllCall("GetForegroundWindow", "Ptr"), "UInt", 3, "Ptr")  ; GA_ROOTOWNER
        return root && (root = this.pl.g.Hwnd || root = this.pl.mpvHwnd)
    }

    ; Mouse resting ~200 ms on the handle / top edge of the video opens the bar;
    ; it closes ~600 ms after the mouse leaves (F3 opens it until you've used it).
    Check() {
        pl := this.pl
        if !pl.cfg["TopBar"] || !this.PlayerActive() || WinGetMinMax(pl.g.Hwnd) = -1 {
            if this.shown
                this.Hide()
            this.ShowHandle(false)
            this.enterAt := 0
            return
        }
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        v := WinRect(pl.vg.Hwnd)
        sc := pl.scale
        zone := mx >= v[1] && mx < v[3] && my >= v[2] - 2 && my < v[2] + Round(12 * sc)
        hx := v[1] + (v[3] - v[1] - this.hw) // 2
        onHandle := mx >= hx - 12 && mx < hx + this.hw + 12 && my >= v[2] - 2 && my < v[2] + this.hh + Round(16 * sc)
        if !this.shown {
            this.ShowHandle(true, hx, v[2] + Round(3 * sc))
            if !(zone || onHandle) {
                this.enterAt := 0
                return
            }
            this.enterAt := this.enterAt || A_TickCount
            if (A_TickCount - this.enterAt >= 200)
                this.Show()
            return
        }
        this.Place()
        b := WinRect(this.g.Hwnd)
        over := mx >= b[1] - 8 && mx < b[3] + 8 && my >= b[2] - 8 && my < b[4] + 8
        if over
            this.sticky := false                              ; used it -> normal auto-hide from now on
        if over || zone || this.sticky
            this.leftAt := 0
        else {
            this.leftAt := this.leftAt || A_TickCount
            if (A_TickCount - this.leftAt >= 600)
                this.Hide()
        }
        MouseGetPos(, , , &ctl, 2)
        if (ctl != this.hot)
            this.SetHot(this.btns.Has(ctl) ? ctl : 0)
    }

    ShowHandle(on, x := 0, y := 0) {
        if on
            DllCall("SetWindowPos", "Ptr", this.hd.Hwnd, "Ptr", -1, "Int", x, "Int", y, "Int", 0, "Int", 0
                  , "UInt", 0x51)                             ; HWND_TOPMOST, NOSIZE|NOACTIVATE|SHOWWINDOW
        else if this.hdShown
            DllCall("ShowWindow", "Ptr", this.hd.Hwnd, "Int", 0)
        this.hdShown := on
    }

    Place() {
        v := WinRect(this.pl.vg.Hwnd)
        DllCall("SetWindowPos", "Ptr", this.g.Hwnd, "Ptr", -1, "Int", v[1] + (v[3] - v[1] - this.w) // 2, "Int", v[2]
              , "Int", 0, "Int", 0, "UInt", 0x51)             ; HWND_TOPMOST, NOSIZE|NOACTIVATE|SHOWWINDOW
    }

    Show() {
        this.Refresh()
        this.ShowHandle(false)
        this.Place()                                          ; positions and shows it, without activating
        this.shown := true, this.leftAt := 0
    }

    Hide() {
        DllCall("ShowWindow", "Ptr", this.g.Hwnd, "Int", 0)
        this.shown := false, this.sticky := false, this.enterAt := 0
        this.SetHot(0)
    }

    Toggle() {
        if this.shown
            return this.Hide()
        this.Show()
        this.sticky := true
    }

    Describe() => Format("enabled={} shown={} visible={} playerActive={} handle={} bar: {}"
        , this.pl.cfg["TopBar"], this.shown, DllCall("IsWindowVisible", "Ptr", this.g.Hwnd)
        , this.PlayerActive(), this.hdShown, DescribeWin(this.g.Hwnd))

    Click(key, *) {
        pl := this.pl
        switch key {
            case "live":    pl.ReloadStream()
            case "chat":    pl.ToggleChat()
            case "side":    pl.SetSide(pl.right ? "Left" : "Right")
            case "chatset": pl.ChatSettings()
            case "full":    pl.ToggleFullscreen()
            case "top":     pl.ToggleOnTop()
            case "mode":    pl.SetVideoMode(pl.cfg["VideoMode"] = "Embedded" ? "Window" : "Embedded")
            case "menu":
                this.Hide()
                pl.ShowMenu()
                return
        }
        this.Refresh()
        if this.shown
            this.Place()
    }

    ; toggles look "on" (purple) when active
    Refresh() {
        pl := this.pl
        onTop := DllCall("GetWindowLongPtr", "Ptr", pl.g.Hwnd, "Int", -20, "Ptr") & 0x8
        states := Map("chat", pl.chatHwnd && pl.chatVisible, "full", pl.isFull, "top", onTop)
        this.byKey["mode"].Text := "Mode: " (pl.cfg["VideoMode"] = "Embedded" ? "Embedded" : "Window")
        for hwnd, b in this.btns {
            b.on := false
            for key, on in states
                if (this.byKey[key] = b.c)
                    b.on := !!on
            this.Paint(b)
        }
    }

    Paint(b) {
        hot := this.hot = b.c.Hwnd
        b.c.Opt("+Background" (b.on ? (hot ? T.accentHi : T.accent) : (hot ? T.hover : T.input)))
        b.c.SetFont("c" (b.on ? "FFFFFF" : T.text))
        b.c.Redraw()
    }

    SetHot(hwnd) {
        old := this.hot, this.hot := hwnd
        if old && this.btns.Has(old)
            this.Paint(this.btns[old])
        if hwnd
            this.Paint(this.btns[hwnd])
    }

    OnMouseMove(wParam, lParam, msg, hwnd) {
        if this.btns.Has(hwnd) && hwnd != this.hot
            this.SetHot(hwnd)
    }
}

; ON/OFF pill switch
class Toggle {
    __New(L, x, y, value := 0, onChange := 0) {
        this.L := L, this.onChange := onChange
        this.c := L.Button(x, y, 52, 28, "", (*) => this.Flip())
        this.c.OnEvent("DoubleClick", (*) => this.Flip())
        this.c.SetFont("s8 bold")
        this.Value := value
    }

    Flip() {
        this.Value := !this._v
        if this.onChange
            this.onChange.Call(this._v)
    }

    Value {
        get => this._v
        set {
            this._v := !!value
            this.c.Text := this._v ? "ON" : "OFF"
            this.L.Paint(this.c, this._v ? T.accent : T.input, this._v ? T.accentHi : T.hover, this._v ? "FFFFFF" : T.dim)
        }
    }
}

; Row of pill buttons, one selected
class Segment {
    __New(L, x, y, w, items, labels) {
        this.L := L, this.items := items, this.cs := [], this._v := ""
        for i, it in items {
            c := L.Button(x + (i - 1) * w, y, w - 4, 34, labels[i], this.Pick.Bind(this, it))
            c.OnEvent("DoubleClick", this.Pick.Bind(this, it))
            this.cs.Push(c)
        }
    }

    Pick(it, *) => this.Value := it

    Value {
        get => this._v
        set {
            this._v := value
            for i, c in this.cs {
                on := this.items[i] = value
                this.L.Paint(c, on ? T.accent : T.input, on ? T.accentHi : T.hover, on ? "FFFFFF" : T.muted)
            }
        }
    }
}

; ===========================================================================
;  helpers
; ===========================================================================
LoadConfig() {
    c := Map()
    for k, v in DEFAULTS
        c[k] := IniRead(INI_FILE, "Settings", k, v)
    ; values that end up in command lines or layout maths must be sane even if the ini was edited
    for k, r in SharedRules()
        c[k] := SharedValue(k, c[k], &v) ? v : DEFAULTS[k]
    for k in ["WinW", "WinH"]
        if !IsInteger(c[k]) || c[k] < 320 || c[k] > 16000
            c[k] := DEFAULTS[k]
    return c
}

SaveConfig(c) {
    for k, v in c
        IniWrite(v, INI_FILE, "Settings", k)
}

GetList(key) {
    out := []
    for s in StrSplit(IniRead(INI_FILE, "Channels", key, ""), "|")
        if (s != "")
            out.Push(s)
    return out
}

SetList(key, arr) => IniWrite(Join(arr), INI_FILE, "Channels", key)

AddRecent(ch) {
    items := [ch "/" A_Now]
    for e in GetList("Recent")
        if (StrSplit(e, "/")[1] != ch && items.Length < 20)
            items.Push(e)
    SetList("Recent", items)
}

Ago(ts) {
    try m := DateDiff(A_Now, ts, "Minutes")
    catch
        return ""
    return m < 1 ? "just now" : m < 60 ? m " min ago" : m < 1440 ? m // 60 " h ago"
         : m < 2880 ? "yesterday" : m // 1440 " days ago"
}

; target: "" = normal mpv window (terminal tests), a number = embed into that HWND (--wid),
; a string = separate borderless window with that title, which the player glues in place.
; secretPipe: named pipe streamlink reads extra arguments (the Twitch auth header) from, as "@<pipe>"
StreamlinkCmd(cfg, ch, target := "", secretPipe := "") {
    if IsInteger(target) && target
        mpv := "--wid=" target " --window-dragging=no"
    else if (target != "")
        mpv := "--title=" target " --no-border --window-dragging=no --window-minimized=yes"
            . " --keepaspect-window=no --auto-window-resize=no --taskbar-progress=no"
            . " --script-opts-append=osc-windowcontrols=no"
    else
        mpv := ""
    if cfg["LowLatency"]
        mpv .= " --profile=low-latency"
    if (mb := IsInteger(cfg["Rewind"]) ? cfg["Rewind"] * 60 : 0) > 0   ; ~1 MiB/s at 1080p60: N minutes seekable in RAM
        mpv .= " --cache=yes --demuxer-seekable-cache=yes --force-seekable=yes"
             . " --demuxer-max-back-bytes=" mb "MiB --demuxer-max-bytes=" mb "MiB"
    if Trim(cfg["MpvArgs"]) != ""
        mpv .= " " Trim(cfg["MpvArgs"])
    mpv := Trim(mpv)
    ; full paths: nothing gets resolved through the current directory or a planted PATH entry
    tools := FindTools(cfg)
    ; every argument quoted the way the C runtime reads it back (ArgQuote)
    cmd := ArgQuote(tools.streamlink != "" ? tools.streamlink : "streamlink")
         . " --player " ArgQuote(tools.mpv != "" ? tools.mpv : "mpv")
    if (mpv != "")
        cmd .= " --player-args " ArgQuote(mpv)
    if cfg["LowLatency"]
        cmd .= " --twitch-low-latency"
    if (secretPipe != "")
        cmd .= " " ArgQuote("@" secretPipe)
    if Trim(cfg["StreamlinkArgs"]) != ""
        cmd .= " " Trim(cfg["StreamlinkArgs"])                ; the user's own extra arguments, as typed
    q := cfg["Quality"] = "best" ? "best" : cfg["Quality"] ",best"      ; fall back if not offered
    return cmd " " ArgQuote("twitch.tv/" ch) " " ArgQuote(q)
}

; ---------- child processes ----------
; streamlink is started WITHOUT a shell, suspended, put into a job object that dies with us, then
; resumed. So closing Puddock (even from Task Manager) also ends streamlink and the mpv it starts,
; we never act on a bare PID that Windows may have handed to someone else, and we can tell exactly
; which processes are "ours" (Owns) — used to hand out the token and to accept mpv's window.
class ChildProcess {
    __New(cmdLine, logPath) {
        this.hProcess := 0, this.job := 0, this.pid := 0
        sa := Buffer(A_PtrSize * 3, 0)                          ; SECURITY_ATTRIBUTES, inheritable
        NumPut("UInt", sa.Size, sa, 0), NumPut("Int", 1, sa, A_PtrSize * 2)
        hLog := DllCall("CreateFile", "Str", logPath, "UInt", 0x40000000, "UInt", 3, "Ptr", sa
                      , "UInt", 2, "UInt", 0x80, "Ptr", 0, "Ptr")    ; GENERIC_WRITE, CREATE_ALWAYS
        if (hLog = -1)
            throw OSError(A_LastError, , "log file " logPath)
        x64 := A_PtrSize = 8
        si := Buffer(x64 ? 104 : 68, 0)                         ; STARTUPINFOW
        NumPut("UInt", si.Size, si, 0)
        NumPut("UInt", 0x101, si, x64 ? 60 : 44)                ; STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW
        NumPut("Ptr", hLog, "Ptr", hLog, si, x64 ? 88 : 60)     ; hStdOutput, hStdError (wShowWindow = SW_HIDE)
        pi := Buffer(A_PtrSize * 2 + 8, 0)                      ; PROCESS_INFORMATION
        cl := Buffer(StrPut(cmdLine) * 2)
        StrPut(cmdLine, cl)
        ok := DllCall("CreateProcess", "Ptr", 0, "Ptr", cl, "Ptr", 0, "Ptr", 0, "Int", true
                    , "UInt", 0x08000004, "Ptr", 0, "Ptr", 0, "Ptr", si, "Ptr", pi)   ; CREATE_NO_WINDOW | CREATE_SUSPENDED
        err := A_LastError
        DllCall("CloseHandle", "Ptr", hLog)
        if !ok
            throw OSError(err, , "streamlink")
        this.hProcess := NumGet(pi, 0, "Ptr"), hThread := NumGet(pi, A_PtrSize, "Ptr")
        this.pid := NumGet(pi, A_PtrSize * 2, "UInt")
        ; JOBOBJECT_EXTENDED_LIMIT_INFORMATION with LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        job := DllCall("CreateJobObject", "Ptr", 0, "Ptr", 0, "Ptr")
        info := Buffer(x64 ? 144 : 112, 0)
        NumPut("UInt", 0x2000, info, 16)
        if job && DllCall("SetInformationJobObject", "Ptr", job, "Int", 9, "Ptr", info, "UInt", info.Size)
              && DllCall("AssignProcessToJobObject", "Ptr", job, "Ptr", this.hProcess)
            this.job := job
        else if job
            DllCall("CloseHandle", "Ptr", job)
        DllCall("ResumeThread", "Ptr", hThread)
        DllCall("CloseHandle", "Ptr", hThread)
    }

    Running => this.hProcess && DllCall("WaitForSingleObject", "Ptr", this.hProcess, "UInt", 0) = 258   ; WAIT_TIMEOUT

    ; is `pid` streamlink itself or anything it started (mpv)?
    Owns(pid) {
        if !pid
            return false
        if !this.job
            return pid = this.pid
        h := DllCall("OpenProcess", "UInt", 0x1000, "Int", false, "UInt", pid, "Ptr")   ; QUERY_LIMITED_INFORMATION
        if !h
            return false
        inJob := 0
        DllCall("IsProcessInJob", "Ptr", h, "Ptr", this.job, "Int*", &inJob)
        DllCall("CloseHandle", "Ptr", h)
        return inJob != 0
    }

    Kill() {
        if this.job
            DllCall("TerminateJobObject", "Ptr", this.job, "UInt", 1)
        else if this.Running
            DllCall("TerminateProcess", "Ptr", this.hProcess, "UInt", 1)
    }

    __Delete() {
        for h in [this.hProcess, this.job]
            if h
                DllCall("CloseHandle", "Ptr", h)
    }
}

; The browser runs its native host in a job that is killed when the host exits (Firefox does,
; at least). The player must outlive that short-lived helper, so leave the job when allowed.
LaunchDetached(cmdLine) {
    for flags in [0x01000000, 0] {                              ; CREATE_BREAKAWAY_FROM_JOB, then plain
        si := Buffer(A_PtrSize = 8 ? 104 : 68, 0)
        NumPut("UInt", si.Size, si, 0)
        pi := Buffer(A_PtrSize * 2 + 8, 0)
        cl := Buffer(StrPut(cmdLine) * 2)
        StrPut(cmdLine, cl)
        if DllCall("CreateProcess", "Ptr", 0, "Ptr", cl, "Ptr", 0, "Ptr", 0, "Int", false
                 , "UInt", flags, "Ptr", 0, "Ptr", 0, "Ptr", si, "Ptr", pi) {
            DllCall("CloseHandle", "Ptr", NumGet(pi, 0, "Ptr"))
            DllCall("CloseHandle", "Ptr", NumGet(pi, A_PtrSize, "Ptr"))
            return true
        }
    }
    return false
}

; ---------- token hand-off to streamlink ----------
; streamlink reads extra arguments from "@<file>" (argparse). We give it "@\\.\pipe\puddock-<random>"
; instead of a file: the token never touches the disk or a command line, the pipe accepts only this
; Windows user and no network clients, and its content goes only to processes inside streamlink's
; job (checked per connection). streamlink parses its arguments twice (again once the Twitch
; plugin is loaded), so the pipe keeps answering until the player sees the stream list, then closes.
class SecretPipe {
    __New(text) {
        this.name := "\\.\pipe\puddock-" RandomHex(16), this.text := text, this.served := 0
        this.sa := UserOnlySecurity()
        this.h := this.NewInstance(true)
    }

    NewInstance(first) {
        h := DllCall("CreateNamedPipe", "Str", this.name
                   , "UInt", 0x2 | (first ? 0x80000 : 0)          ; OUTBOUND (+ FIRST_PIPE_INSTANCE: no squatting)
                   , "UInt", 0x9                                  ; BYTE | NOWAIT | REJECT_REMOTE_CLIENTS
                   , "UInt", 4, "UInt", 4096, "UInt", 0, "UInt", 0, "Ptr", this.sa.buf, "Ptr")
        if (h = -1)
            throw OSError(A_LastError, , "named pipe")
        return h
    }

    ; poll from a timer: answer a waiting client if it belongs to `child`
    Serve(child) {
        if !this.h
            return
        ok := DllCall("ConnectNamedPipe", "Ptr", this.h, "Ptr", 0), err := A_LastError
        if ok || err = 536                                        ; just (re)armed / ERROR_PIPE_LISTENING
            return
        if (err != 535 && err != 232)                             ; ERROR_PIPE_CONNECTED / ERROR_NO_DATA
            return
        next := this.NewInstance(false)                           ; keep the name answering
        pid := 0
        if (err = 535 && DllCall("GetNamedPipeClientProcessId", "Ptr", this.h, "UInt*", &pid) && child.Owns(pid)) {
            n := StrPut(this.text, "UTF-8") - 1, buf := Buffer(n + 1), written := 0
            StrPut(this.text, buf, n + 1, "UTF-8")
            DllCall("WriteFile", "Ptr", this.h, "Ptr", buf, "UInt", n, "UInt*", &written, "Ptr", 0)
            DllCall("FlushFileBuffers", "Ptr", this.h)            ; returns once the client has read it
            try DllCall("RtlZeroMemory", "Ptr", buf, "UPtr", buf.Size)
            this.served++
        }
        DllCall("CloseHandle", "Ptr", this.h)                     ; close, not disconnect: a clean EOF for Python
        this.h := next
    }

    Close() {
        if this.h
            DllCall("CloseHandle", "Ptr", this.h)
        this.h := 0, this.text := ""
        if this.sa.psd
            DllCall("LocalFree", "Ptr", this.sa.psd)
        this.sa.psd := 0
    }
}

; SECURITY_ATTRIBUTES whose DACL grants access to the current user only (protected, nothing inherited)
UserOnlySecurity() {
    psd := 0
    if !DllCall("advapi32\ConvertStringSecurityDescriptorToSecurityDescriptorW"
              , "Str", "D:P(A;;GA;;;" CurrentUserSid() ")", "UInt", 1, "Ptr*", &psd, "Ptr", 0)
        throw OSError(A_LastError, , "security descriptor")
    buf := Buffer(A_PtrSize * 3, 0)
    NumPut("UInt", buf.Size, buf, 0), NumPut("Ptr", psd, buf, A_PtrSize)
    return {buf: buf, psd: psd}
}

CurrentUserSid() {
    hTok := 0, size := 0, str := 0
    DllCall("advapi32\OpenProcessToken", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt", 0x8, "Ptr*", &hTok)  ; TOKEN_QUERY
    DllCall("advapi32\GetTokenInformation", "Ptr", hTok, "Int", 1, "Ptr", 0, "UInt", 0, "UInt*", &size)  ; TokenUser
    info := Buffer(size)
    ok := DllCall("advapi32\GetTokenInformation", "Ptr", hTok, "Int", 1, "Ptr", info, "UInt", size, "UInt*", &size)
    DllCall("CloseHandle", "Ptr", hTok)
    if !ok || !DllCall("advapi32\ConvertSidToStringSidW", "Ptr", NumGet(info, 0, "Ptr"), "Ptr*", &str)
        throw OSError(A_LastError, , "user SID")
    sid := StrGet(str)
    DllCall("LocalFree", "Ptr", str)
    return sid
}

WindowPid(h) {
    pid := 0
    DllCall("GetWindowThreadProcessId", "Ptr", h, "UInt*", &pid)
    return pid
}

; One argument, quoted the way CommandLineToArgvW / the C runtime / Python read it back:
; backslashes are only special right before a quote, so double those and escape the quote.
ArgQuote(s) {
    s := String(s)
    if (s != "" && !RegExMatch(s, '[ \t\n\v"]'))
        return s
    out := '"', bs := 0
    Loop Parse s {
        c := A_LoopField
        if (c = "\") {
            bs++
            continue
        }
        out .= c = '"' ? StrRepeat("\", bs * 2 + 1) '"' : StrRepeat("\", bs) c
        bs := 0
    }
    return out StrRepeat("\", bs * 2) '"'
}

StrRepeat(s, n) {
    out := ""
    Loop n
        out .= s
    return out
}


; ---------- dependencies ----------
; streamlink / mpv as full paths: the configured path, then where installers put them (winget's
; links, Program Files, the user's own folders), and only then PATH — re-read from the registry so
; a fresh install is found without logging off. Shared spots other accounts can write to (e.g.
; ProgramData) are not searched; anything else on PATH is shown in Setup with its full path.
FindTools(cfg) {
    lad := EnvGet("LOCALAPPDATA"), pf := EnvGet("ProgramFiles"), pf86 := EnvGet("ProgramFiles(x86)")
    home := EnvGet("USERPROFILE"), links := lad "\Microsoft\WinGet\Links"
    return { streamlink: FindTool(cfg["StreamlinkPath"], "streamlink"
                , [links, pf "\Streamlink\bin", pf86 "\Streamlink\bin", lad "\Programs\Streamlink\bin", home "\scoop\shims"])
           , mpv: FindTool(cfg["MpvPath"], "mpv"
                , [links, pf "\MPV Player", pf "\mpv", lad "\Programs\mpv", home "\scoop\apps\mpv\current", home "\scoop\shims"]) }
}

FindTool(configured, name, knownDirs) {
    configured := Trim(configured, ' "')
    if InStr(configured, "\")                                  ; an explicit path: that or nothing
        return FileExist(configured) && !InStr(FileExist(configured), "D") ? configured : ""
    for list in [knownDirs, PathDirs()]
        for dir in list
            if FileExist(p := dir "\" name ".exe") && !InStr(FileExist(p), "D")
                return p
    return ""
}

PathDirs() {
    dirs := []
    for src in [EnvGet("PATH"), RegValue("HKCU\Environment", "Path")
              , RegValue("HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment", "Path")]
        for d in StrSplit(ExpandEnv(src), ";")
            if RegExMatch(d := Trim(d, ' "'), "^(?:[A-Za-z]:\\|\\\\)") && !HasVal(dirs, d)   ; absolute only
                dirs.Push(RTrim(d, "\"))
    return dirs
}

; "" when streamlink and mpv can be found, otherwise a message saying what's missing
MissingTools(cfg) {
    tools := FindTools(cfg), msg := ""
    if (tools.streamlink = "")
        msg .= "• streamlink`n"
    if (tools.mpv = "")
        msg .= "• mpv`n"
    return msg = "" ? "" : "Can't find:`n`n" msg "`nOpen " APP " → Setup to install them (or set their paths)."
}

; winget verifies the installer's hash from its manifest; the id comes only from our constants
WingetInstall(id) {
    if (id != STREAMLINK_WINGET && id != MPV_WINGET)
        throw ValueError("unexpected package id")
    if !FileExist(wg := EnvGet("LOCALAPPDATA") "\Microsoft\WindowsApps\winget.exe")
        return 0
    if RunWait(ArgQuote(wg) " show --id " id " --exact --source winget", , "Hide") != 0
        return 0                                                ; no such package
    Run(ArgQuote(wg) " install --id " id " --exact --source winget --accept-package-agreements --accept-source-agreements", , , &pid)
    return pid
}

; ---------- browser used for the chat when the extension isn't there ----------
FindChromium(custom := "") {
    static exes := ["brave.exe", "chrome.exe", "msedge.exe", "vivaldi.exe", "opera.exe", "chromium.exe"]
    custom := Trim(custom, ' "')
    if (custom != "" && FileExist(custom))
        return custom
    SplitPath(def := DefaultBrowserExe(), &name)
    if (def != "" && HasVal(exes, StrLower(name)) && FileExist(def))   ; the user's default, if Chromium
        return def
    for exe in exes
        for root in ["HKCU", "HKLM"]
            if (p := RegValue(root "\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\" exe)) != "" && FileExist(p)
                return p
    edge := EnvGet("ProgramFiles(x86)") "\Microsoft\Edge\Application\msedge.exe"   ; always there on 10/11
    return FileExist(edge) ? edge : ""
}

DefaultBrowserExe() {
    progId := RegValue("HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice", "ProgId")
    cmd := progId = "" ? "" : RegValue("HKCR\" progId "\shell\open\command")
    return RegExMatch(cmd, '^\s*"([^"]+)"', &m) || RegExMatch(cmd, "^\s*(\S+)", &m) ? m[1] : ""
}

; ---------- chat helpers ----------
ChatUrl(ch, dark, nonce := "") {
    q := []
    if dark
        q.Push("darkpopout")
    if (nonce != "")
        q.Push("puddock=" nonce)
    return "https://www.twitch.tv/popout/" ch "/chat" (q.Length ? "?" Join(q, "&") : "")
}

; One-time values the app hands to the browser through a URL (chat window / connect request).
; The extension asks us (checkNonce) before acting on one, so a web page can't fake them.
RememberNonce(kind, nonce) => IniWrite(nonce "|" A_Now, INI_FILE, "State", kind "Nonce")

CheckNonce(kind, nonce, consume) {
    if !RegExMatch(nonce, "^[a-f0-9]{16,64}$")
        return false
    parts := StrSplit(IniRead(INI_FILE, "State", kind "Nonce", ""), "|")
    try fresh := parts.Length = 2 && parts[1] == nonce && DateDiff(A_Now, parts[2], "Minutes") < (kind = "Chat" ? 10 : 2)
    catch
        fresh := false
    if (fresh && consume)
        IniDelete(INI_FILE, "State", kind "Nonce")
    return fresh
}

ExtensionSeenRecently() {
    seen := IniRead(INI_FILE, "State", "ExtensionSeen", "")
    try return seen != "" && DateDiff(A_Now, seen, "Days") <= 30
    return false
}

RandomHex(bytes) {
    buf := Buffer(bytes)
    DllCall("bcrypt\BCryptGenRandom", "Ptr", 0, "Ptr", buf, "UInt", bytes, "UInt", 2)   ; system RNG
    out := ""
    Loop bytes
        out .= Format("{:02x}", NumGet(buf, A_Index - 1, "UChar"))
    return out
}

WindowText(h) {
    buf := Buffer(1024, 0)
    DllCall("GetWindowText", "Ptr", h, "Ptr", buf, "Int", 512)
    return StrGet(buf)
}

; ---------- browser connection (native messaging) ----------
; Started by a browser, argv holds the caller: "chrome-extension://<id>/" (Chromium) or
; "<manifest path> <extension id>" (Firefox).
IsNativeHostLaunch() {
    if !A_Args.Length
        return false
    return RegExMatch(A_Args[1], "^chrome-extension://[a-p]{32}/?$")
        || A_Args.Length >= 2 && A_Args[2] = GECKO_ID && SubStr(A_Args[1], -5) = ".json"
}

; One request -> one reply over stdin/stdout (4-byte length + UTF-8 JSON). No window, no tray
; icon. Only the extension IDs at the top of this file get an answer, and only for the fixed
; commands in HostHandle.
NativeHost() {
    A_IconHidden := true
    allowed := RegExMatch(A_Args[1], "^chrome-extension://([a-p]{32})/?$", &m)
        ? HasVal(AllowedChromiumIds(), m[1]) : A_Args.Length >= 2 && A_Args[2] = GECKO_ID
    if !allowed
        ExitApp(1)
    PrepareDataDir()
    hIn := DllCall("GetStdHandle", "Int", -10, "Ptr"), hOut := DllCall("GetStdHandle", "Int", -11, "Ptr")
    Loop {
        hdr := Buffer(4)
        if !ReadExact(hIn, hdr, 4)
            break
        n := NumGet(hdr, "UInt")
        if (n = 0 || n > 65536)                                 ; our messages are tiny
            break
        buf := Buffer(n)
        if !ReadExact(hIn, buf, n)
            break
        try reply := HostHandle(Json.Parse(StrGet(buf, n, "UTF-8")))
        catch
            reply := Map("ok", 0, "error", "bad request")
        WriteMessage(hOut, reply)
    }
    ExitApp
}

ReadExact(h, buf, n) {
    got := 0
    while (got < n) {
        read := 0
        if !DllCall("ReadFile", "Ptr", h, "Ptr", buf.Ptr + got, "UInt", n - got, "UInt*", &read, "Ptr", 0) || !read
            return false
        got += read
    }
    return true
}

WriteMessage(h, obj) {
    text := Json.Stringify(obj)
    len := StrPut(text, "UTF-8") - 1
    buf := Buffer(4 + len + 1)
    NumPut("UInt", len, buf)
    StrPut(text, buf.Ptr + 4, len + 1, "UTF-8")
    written := 0
    DllCall("WriteFile", "Ptr", h, "Ptr", buf, "UInt", 4 + len, "UInt*", &written, "Ptr", 0)
}

HostHandle(msg) {
    if !(msg is Map)
        return Map("ok", 0, "error", "bad request")
    IniWrite(A_Now, INI_FILE, "State", "ExtensionSeen")
    switch msg.Get("cmd", "") {
        case "hello", "status":
            return HostStatus()
        case "watch":
            ch := ParseChannel(msg.Get("channel", ""))
            if (ch = "")
                return Map("ok", 0, "error", "invalid channel")
            nonce := msg.Get("nonce", "")
            if !RegExMatch(nonce, "^[a-f0-9]{16,64}$")
                nonce := ""
            if MissingTools(LoadConfig()) != "" {
                LaunchDetached(SelfCmd("--setup"))
                return Map("ok", 0, "error", "streamlink or mpv is missing — Puddock's Setup is open", "setup", 1)
            }
            running := PlayerWindow(ch) != 0                    ; already open: just bring it up
            args := ["--watch", ch]
            if (nonce != "" && !running) {
                args.Push("--chat-nonce", nonce)
                RememberNonce("Chat", nonce)
            }
            if !LaunchDetached(SelfCmd(args*))
                return Map("ok", 0, "error", "could not start the player")
            return Map("ok", 1, "chat", running ? 0 : 1, "chatDark", LoadConfig()["ChatDark"] ? 1 : 0)
        case "getSettings":
            return Map("ok", 1, "settings", SharedSettings())
        case "setSettings":
            incoming := msg.Get("settings", "")
            if !(incoming is Map)
                return Map("ok", 0, "error", "bad settings")
            clean := Map()
            for k, v in incoming {                                    ; validate everything before writing anything
                if !SharedValue(k, v, &out)
                    return Map("ok", 0, "error", "invalid value for " k)
                clean[k] := out
            }
            for k, v in clean
                IniWrite(v, INI_FILE, "Settings", k)
            return Map("ok", 1, "settings", SharedSettings())
        case "setToken":
            tok := CleanToken(msg.Get("token", ""))
            if (tok = "")
                return Map("ok", 0, "error", "not a Twitch token")
            try info := ValidateToken(tok)
            catch
                return Map("ok", 0, "error", "Twitch could not be reached")
            if !info
                return Map("ok", 0, "error", "Twitch rejected the token")
            if (info.clientId != WEB_CLIENT_ID)
                return Map("ok", 0, "error", "not a twitch.tv browser login")
            SaveToken(tok, info.login)
            return Map("ok", 1, "login", info.login)
        case "clearToken":
            ClearToken()
            return Map("ok", 1)
        case "checkNonce":                                      ; was this nonce really issued by us?
            kind := msg.Get("kind", "")
            if (kind != "Chat" && kind != "Connect")
                return Map("ok", 0, "error", "bad request")
            return Map("ok", CheckNonce(kind, msg.Get("nonce", ""), kind = "Connect") ? 1 : 0)
        case "openApp":
            page := msg.Get("page", "")
            LaunchDetached(SelfCmd(page = "setup" ? "--setup" : page = "settings" ? "--settings" : ""))
            return Map("ok", 1)
    }
    return Map("ok", 0, "error", "unknown command")
}

HostStatus() {
    tools := FindTools(LoadConfig()), login := IniRead(INI_FILE, "Account", "Login", "")
    return Map("ok", 1, "app", APP, "version", VERSION
        , "streamlink", tools.streamlink != "" ? 1 : 0, "mpv", tools.mpv != "" ? 1 : 0
        , "account", LoadToken() = "" ? "" : login != "" ? login : "(unverified)")
}

; Settings the extension may read and change. Paths and raw streamlink/mpv arguments are
; deliberately NOT here: whoever can set those can make the app run any program.
SharedRules() {
    static rules := Map(
        "Quality",          {enum: ["best", "1080p60", "720p60", "480p", "360p", "audio_only"]},
        "LowLatency",       {bool: 1},
        "Rewind",           {enum: [0, 5, 15, 30]},
        "VideoMode",        {enum: ["Embedded", "Window"]},
        "TopBar",           {bool: 1},
        "ChatWidth",        {min: 200, max: 1200},
        "ChatSide",         {enum: ["Left", "Right"]},
        "ChatDark",         {bool: 1},
        "ChatInFullscreen", {bool: 1},
        "RememberPos",      {bool: 1},
        "StartFullscreen",  {bool: 1},
        "AlwaysOnTop",      {bool: 1})
    return rules
}

SharedSettings() {
    cfg := LoadConfig(), out := Map()
    for k, r in SharedRules()
        out[k] := IsInteger(cfg[k]) ? Integer(cfg[k]) : cfg[k]
    return out
}

SharedValue(key, v, &out) {
    rules := SharedRules()
    if !rules.Has(key)
        return false
    r := rules[key]
    if r.HasOwnProp("bool") {
        if !(IsInteger(v) && (v = 0 || v = 1))
            return false
        out := Integer(v)
    } else if r.HasOwnProp("enum") {
        for e in r.enum
            if (String(v) == String(e)) {
                out := e
                return true
            }
        return false
    } else {
        if !IsInteger(v) || v < r.min || v > r.max
            return false
        out := Integer(v)
    }
    return true
}

; the running player for a channel (title "<channel> · Puddock"), or 0
PlayerWindow(ch) {
    SetTitleMatchMode("RegEx")
    return WinExist("^" ch " · " APP "$ ahk_class AutoHotkeyGUI")
}

HostDir() => DATA_DIR "\native-host"

AllowedChromiumIds() {
    ids := CHROMIUM_IDS.Clone()
    if !A_IsCompiled || IniRead(INI_FILE, "Developer", "AllowDevExtension", 0) = 1
        ids.Push(DEV_EXT_ID)
    return ids
}

; What the browsers start. A compiled build is its own host; a plain script needs a tiny
; .cmd in front, since browsers only start programs.
HostExecutable() {
    if A_IsCompiled
        return A_ScriptFullPath
    wrapper := HostDir() "\puddock-host.cmd"
    WriteText(wrapper, '@"' StrReplace(A_AhkPath, "%", "%%") '" "' StrReplace(A_ScriptFullPath, "%", "%%") '" %*`r`n', "CP0")
    return wrapper
}

RegisterNativeHost() {
    DirCreate(HostDir())
    origins := []
    for id in AllowedChromiumIds()
        origins.Push("chrome-extension://" id "/")
    base := Map("name", NATIVE_HOST, "description", APP " browser connection", "path", HostExecutable(), "type", "stdio")
    chromium := base.Clone(), chromium["allowed_origins"] := origins
    firefox := base.Clone(), firefox["allowed_extensions"] := [GECKO_ID]
    WriteText(cm := HostDir() "\" NATIVE_HOST ".chromium.json", Json.Stringify(chromium))
    WriteText(fm := HostDir() "\" NATIVE_HOST ".firefox.json", Json.Stringify(firefox))
    for k in HOST_REG_KEYS
        RegWrite(cm, "REG_SZ", "HKCU\Software\" k "\NativeMessagingHosts\" NATIVE_HOST)
    RegWrite(fm, "REG_SZ", "HKCU\Software\Mozilla\NativeMessagingHosts\" NATIVE_HOST)
    RemoveLegacyProtocol()
}

; the old twitchmpv:// handler (any web page could trigger it) — only if it's ours
RemoveLegacyProtocol() {
    cmd := RegValue(LEGACY_PROTO "\shell\open\command")
    if (cmd != "" && (InStr(cmd, "twitch-mpv") || InStr(cmd, A_ScriptFullPath)))
        try RegDeleteKey(LEGACY_PROTO)
}

UnregisterNativeHost() {
    for k in HOST_REG_KEYS
        try RegDeleteKey("HKCU\Software\" k "\NativeMessagingHosts\" NATIVE_HOST)
    try RegDeleteKey("HKCU\Software\Mozilla\NativeMessagingHosts\" NATIVE_HOST)
    for f in [NATIVE_HOST ".chromium.json", NATIVE_HOST ".firefox.json", "puddock-host.cmd"]
        try FileDelete(HostDir() "\" f)                       ; our files only, no recursive delete
    try DirDelete(HostDir())
    RemoveLegacyProtocol()
}

; registered for Chromium browsers and pointing at this copy of the app?
NativeHostRegistered() {
    manifest := RegValue("HKCU\Software\Google\Chrome\NativeMessagingHosts\" NATIVE_HOST)
    try return manifest != "" && Json.Parse(FileRead(manifest, "UTF-8"))["path"]
        = (A_IsCompiled ? A_ScriptFullPath : HostDir() "\puddock-host.cmd")
    return false
}

; Settings live in %APPDATA%\Puddock. Once, take over what the old "twitch-mpv" script had — but
; only validated values and channel names: never paths or raw arguments from a file that may
; sit in a folder other accounts can write to.
PrepareDataDir() {
    if !DirExist(DATA_DIR)
        DirCreate(DATA_DIR)
    Loop Files EnvGet("LOCALAPPDATA") "\Puddock\run\*.conf"       ; token files of an earlier build
        try FileDelete(A_LoopFileFullPath)
    try DirDelete(EnvGet("LOCALAPPDATA") "\Puddock\run")
    if FileExist(INI_FILE)
        return
    for old in [A_ScriptDir "\twitch-mpv.ini", A_ScriptDir "\..\twitch-mpv.ini"] {
        if !FileExist(old)
            continue
        for k, r in SharedRules()
            if SharedValue(k, IniRead(old, "Settings", k, ""), &v)
                IniWrite(v, INI_FILE, "Settings", k)
        favs := [], rec := []
        for e in StrSplit(IniRead(old, "Channels", "Favorites", ""), "|")
            if (ch := ParseChannel(e)) != ""
                favs.Push(ch)
        for e in StrSplit(IniRead(old, "Channels", "Recent", ""), "|")
            if (ch := ParseChannel(StrSplit(e, "/")[1])) != "" && IsInteger(ts := StrSplit(e "/", "/")[2])
                rec.Push(ch "/" ts)
        SetList("Favorites", favs), SetList("Recent", rec)
        if (blob := IniRead(old, "Account", "Token", "")) != "" && (tok := Unprotect(blob)) != ""
            CredWrite(CRED_TARGET, tok)                             ; DPAPI: only ever our own user's
        return
    }
}

; logs of a crashed run were never scrubbed: do it at the next start
ScrubStaleLogs() {
    Loop Files A_Temp "\puddock-*.log"
        ScrubLog(A_LoopFileFullPath)
}

RegValue(key, name := "") {
    try return RegRead(key, name)
    return ""
}

ExpandEnv(s) {
    buf := Buffer(65536, 0)
    DllCall("ExpandEnvironmentStrings", "Str", s, "Ptr", buf, "UInt", 32768)
    return StrGet(buf)
}

WriteText(path, text, encoding := "UTF-8-RAW") {
    f := FileOpen(path, "w", encoding)
    f.Write(text)
    f.Close()
}

; Only ONE player at a time. Same channel -> bring it to the front. Another channel -> close the
; running player (it cleans up streamlink, mpv and the chat on exit) and take its place.
LockPlayer(ch) {
    global playerMutex
    SetTitleMatchMode("RegEx")
    closed := 0, deadline := A_TickCount + 10000
    Loop {
        playerMutex := DllCall("CreateMutex", "Ptr", 0, "Int", 0, "Str", "puddock-player", "Ptr")
        if (A_LastError != 183)                              ; ERROR_ALREADY_EXISTS
            return true
        DllCall("CloseHandle", "Ptr", playerMutex)
        if (hwnd := WinExist("^\w+ · " APP "$ ahk_class AutoHotkeyGUI")) {
            if (WinGetTitle(hwnd) = ch " · " APP) {
                BringToFront(hwnd)
                return false
            }
            if (hwnd != closed)
                WinClose(hwnd), closed := hwnd
        }
        if (A_TickCount > deadline) {
            TrayTip("Another player is still running — close it and try again.", APP)
            Sleep(2000)                                      ; let the notification show before exiting
            return false
        }
        Sleep(100)
    }
}

; Only one launcher: a second start just brings the open one to the front.
LockLauncher() {
    global launcherMutex := DllCall("CreateMutex", "Ptr", 0, "Int", 0, "Str", "puddock-launcher", "Ptr")
    if (A_LastError != 183)
        return true
    if (hwnd := WinExist("^" APP "$ ahk_class ^AutoHotkeyGUI$"))
        BringToFront(hwnd)
    return false
}

BringToFront(hwnd) {
    if (WinGetMinMax(hwnd) = -1)
        WinRestore(hwnd)
    WinActivate(hwnd)
}

; "xqc", "https://www.twitch.tv/xqc" -> "xqc"
ParseChannel(s) {
    s := Trim(String(s))
    if RegExMatch(s, "i)twitch\.tv/(?:popout/|moderator/)?([^/?#]+)", &m)
        s := m[1]
    s := StrLower(Trim(s, " /"))
    return RegExMatch(s, "^[a-z0-9_]{1,25}$") ? s : ""
}

SelfCmd(args*) {
    cmd := A_IsCompiled ? ArgQuote(A_ScriptFullPath) : ArgQuote(A_AhkPath) " " ArgQuote(A_ScriptFullPath)
    for a in args
        cmd .= " " ArgQuote(a)
    return cmd
}


; ---------- Twitch login ----------
; The token lives in Windows Credential Manager (a generic credential for this user on this PC;
; the user can see / remove the entry there, not read it). The app never shows it and never puts
; it on a command line or in a file: streamlink reads it from a private named pipe (see StartStream).
LoadToken() {
    static migrated := false
    if !migrated {
        migrated := true
        MigrateIniToken()
    }
    return CredRead(CRED_TARGET)
}

SaveToken(token, login) {
    CredWrite(CRED_TARGET, token)
    IniWrite(login, INI_FILE, "Account", "Login")
    IniWrite(A_Now, INI_FILE, "Account", "Checked")
}

ClearToken() {
    CredDelete(CRED_TARGET)
    try IniDelete(INI_FILE, "Account")
}

; earlier builds kept the token DPAPI-encrypted in settings.ini: move it, then drop it there
MigrateIniToken() {
    v := IniRead(INI_FILE, "Account", "Token", "")
    if (v = "")
        return
    if (tok := Unprotect(v)) != ""
        CredWrite(CRED_TARGET, tok)
    IniDelete(INI_FILE, "Account", "Token")
}

; CREDENTIALW: Flags, Type, TargetName, Comment, LastWritten, CredentialBlobSize, CredentialBlob,
; Persist, AttributeCount, Attributes, TargetAlias, UserName
CredWrite(target, secret) {
    x64 := A_PtrSize = 8
    n := StrPut(secret, "UTF-8") - 1
    blob := Buffer(n + 1)
    StrPut(secret, blob, n + 1, "UTF-8")
    c := Buffer(x64 ? 80 : 52, 0)
    NumPut("UInt", 1, c, 4)                                     ; CRED_TYPE_GENERIC
    NumPut("Ptr", StrPtr(target), c, 8)
    NumPut("UInt", n, c, x64 ? 32 : 24)
    NumPut("Ptr", blob.Ptr, c, x64 ? 40 : 28)
    NumPut("UInt", 2, c, x64 ? 48 : 32)                         ; CRED_PERSIST_LOCAL_MACHINE (not roaming)
    NumPut("Ptr", StrPtr(A_UserName), c, x64 ? 72 : 48)
    if !DllCall("advapi32\CredWriteW", "Ptr", c, "UInt", 0)
        throw OSError(A_LastError, , "Windows Credential Manager")
}

CredRead(target) {
    p := 0
    if !DllCall("advapi32\CredReadW", "Str", target, "UInt", 1, "UInt", 0, "Ptr*", &p)
        return ""
    x64 := A_PtrSize = 8
    n := NumGet(p, x64 ? 32 : 24, "UInt")
    s := n ? StrGet(NumGet(p, x64 ? 40 : 28, "Ptr"), n, "UTF-8") : ""
    DllCall("advapi32\CredFree", "Ptr", p)
    return s
}

CredDelete(target) => DllCall("advapi32\CredDeleteW", "Str", target, "UInt", 1, "UInt", 0)

; accepts "abc…", "OAuth abc…", "auth-token=abc…"
CleanToken(s) {
    s := RegExReplace(Trim(s), "i)^(oauth\s+|auth-token=)")
    return RegExMatch(s, "^[A-Za-z0-9]{20,64}$") ? s : ""
}

; -> {login, clientId, expires}; 0 if Twitch rejects the token; throws if Twitch can't be reached
ValidateToken(token) {
    req := ComObject("WinHttp.WinHttpRequest.5.1")
    req.SetTimeouts(3000, 3000, 5000, 5000)
    req.Option[6] := false                                      ; never follow a redirect with the token
    req.Open("GET", "https://id.twitch.tv/oauth2/validate", false)
    req.SetRequestHeader("Authorization", "OAuth " token)
    req.Send()
    if (req.Status = 401)
        return 0
    if (req.Status != 200)
        throw Error("Twitch answered HTTP " req.Status)
    j := req.ResponseText
    return { login:    RegExMatch(j, '"login"\s*:\s*"([^"]+)"', &m) ? m[1] : ""
           , clientId: RegExMatch(j, '"client_id"\s*:\s*"([^"]+)"', &m) ? m[1] : ""
           , expires:  RegExMatch(j, '"expires_in"\s*:\s*(\d+)', &m) ? Integer(m[1]) : 0 }
}

; Error texts and logs can contain the full streamlink command line: hide the token in them.
MaskToken(text) {
    try token := LoadToken()
    catch
        return text
    return token != "" ? StrReplace(text, token, "<token>") : text
}

ScrubLog(path) {
    try {
        text := FileRead(path)
        if (text != (masked := MaskToken(text)))
            FileOpen(path, "w").Write(masked)
    }
}

; DPAPI decrypt — only to migrate tokens saved by earlier builds
Unprotect(b64) {
    n := 0
    if !DllCall("crypt32\CryptStringToBinaryW", "Str", b64, "UInt", 0, "UInt", 1, "Ptr", 0, "UInt*", &n, "Ptr", 0, "Ptr", 0)
        return ""
    bin := Buffer(n)
    DllCall("crypt32\CryptStringToBinaryW", "Str", b64, "UInt", 0, "UInt", 1, "Ptr", bin, "UInt*", &n, "Ptr", 0, "Ptr", 0)
    blobIn := Blob(bin.Ptr, n), blobOut := Blob(0, 0)
    if !DllCall("crypt32\CryptUnprotectData", "Ptr", blobIn, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "UInt", 1, "Ptr", blobOut)
        return ""                                            ; other user / other PC: treat as logged out
    p := NumGet(blobOut, A_PtrSize, "Ptr")
    str := StrGet(p, NumGet(blobOut, 0, "UInt"), "UTF-8")
    DllCall("LocalFree", "Ptr", p)
    return str
}

; DATA_BLOB { DWORD cbData; BYTE *pbData }
Blob(ptr, size) {
    b := Buffer(A_PtrSize * 2, 0)
    NumPut("UInt", size, b, 0), NumPut("Ptr", ptr, b, A_PtrSize)
    return b
}

MakeShortcut(dir) {
    lnk := dir "\" APP ".lnk"
    if A_IsCompiled
        FileCreateShortcut(A_ScriptFullPath, lnk, A_ScriptDir, , APP)
    else
        FileCreateShortcut(A_AhkPath, lnk, A_ScriptDir, '"' A_ScriptFullPath '"', APP, FileExist(ICON) ? ICON : "")
}

FlashText(ctl, text) {
    orig := ctl.Text
    ctl.Text := text
    SetTimer(() => ctl.Text := orig, -1400)
}

MonitorRect(cx, cy, &l, &t, &r, &b) {
    l := 0, t := 0, r := A_ScreenWidth, b := A_ScreenHeight
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (cx >= ml && cx < mr && cy >= mt && cy < mb) {
            l := ml, t := mt, r := mr, b := mb
            return
        }
    }
}

OnScreen(x, y) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (x >= ml && x < mr && y >= mt && y < mb)
            return true
    }
    return false
}

; "0x1234 class=mpv pid=… rect=… style=… ex=… enabled visible dpi=…" for diagnostics
DescribeWin(h) {
    if !h || !DllCall("IsWindow", "Ptr", h)
        return "(none)"
    cls := Buffer(512)
    DllCall("GetClassName", "Ptr", h, "Ptr", cls, "Int", 256)
    pid := 0, tid := DllCall("GetWindowThreadProcessId", "Ptr", h, "UInt*", &pid, "UInt")
    r := WinRect(h)
    dpi := DllCall("GetAwarenessFromDpiAwarenessContext", "Ptr", DllCall("GetWindowDpiAwarenessContext", "Ptr", h, "Ptr"), "Int")
    return Format("0x{:X} class={} pid={} tid={} rect={},{} {}x{} style=0x{:08X} ex=0x{:08X} {} {} dpiAware={} parent=0x{:X}"
        , h, StrGet(cls), pid, tid, r[1], r[2], r[3] - r[1], r[4] - r[2]
        , DllCall("GetWindowLongPtr", "Ptr", h, "Int", -16, "Ptr") & 0xFFFFFFFF
        , DllCall("GetWindowLongPtr", "Ptr", h, "Int", -20, "Ptr") & 0xFFFFFFFF
        , DllCall("IsWindowEnabled", "Ptr", h) ? "enabled" : "DISABLED"
        , DllCall("IsWindowVisible", "Ptr", h) ? "visible" : "hidden"
        , dpi, DllCall("GetAncestor", "Ptr", h, "UInt", 1, "Ptr"))
}

FocusOfForeground() {
    gti := Buffer(A_PtrSize = 8 ? 72 : 48, 0)          ; GUITHREADINFO
    NumPut("UInt", gti.Size, gti, 0)
    return DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gti) ? NumGet(gti, A_PtrSize = 8 ? 16 : 12, "Ptr") : 0
}

WinRect(hwnd) {
    rc := Buffer(16)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", rc)
    return [NumGet(rc, 0, "Int"), NumGet(rc, 4, "Int"), NumGet(rc, 8, "Int"), NumGet(rc, 12, "Int")]
}

FindDescendant(parent, cls) {
    if (h := DllCall("FindWindowEx", "Ptr", parent, "Ptr", 0, "Str", cls, "Ptr", 0, "Ptr"))
        return h
    child := 0
    while (child := DllCall("FindWindowEx", "Ptr", parent, "Ptr", child, "Ptr", 0, "Ptr", 0, "Ptr"))
        if (h := FindDescendant(child, cls))
            return h
    return 0
}

; Any unhandled error: say what happened, copy the details, and quit cleanly (OnExit still stops
; streamlink/mpv/chat) instead of leaving a half-built window and an empty tray menu behind.
Crash(e, mode) {
    static crashed := false
    if crashed
        return 1
    crashed := true
    if HOST_MODE                                    ; no UI for the browser's helper process
        ExitApp(1)
    details := MaskToken(APP " error: " e.Message (e.Extra != "" ? "`nSpecifically: " e.Extra : "")
             . "`nLine " e.Line ": " Trim(StrSplit(e.Stack, "`n")[1]))
    A_Clipboard := details "`n`n" MaskToken(e.Stack)
    MsgBox(details "`n`n(The details are copied to the clipboard.) " APP " will close now.", APP, "Iconx")
    ExitApp(1)
}

MenuCheck(m, item, on) {
    if on
        m.Check(item)
    else
        m.Uncheck(item)
}

MenuEnable(m, item, on) {
    if on
        m.Enable(item)
    else
        m.Disable(item)
}

MoveWin(hwnd, x, y, w, h) => DllCall("MoveWindow", "Ptr", hwnd, "Int", x, "Int", y, "Int", w, "Int", h, "Int", 1)

SetVis(c, visible) {
    if (c is Gui) {
        if visible
            c.Show("NA")
        else
            c.Hide()
    } else
        c.Visible := visible
}

RoundCtl(hwnd, r := 6) {
    rc := Buffer(16)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", rc)
    w := NumGet(rc, 8, "Int") - NumGet(rc, 0, "Int"), h := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
    r := Round(r * A_ScreenDPI / 96)
    rgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", w + 1, "Int", h + 1, "Int", r, "Int", r, "Ptr")
    DllCall("SetWindowRgn", "Ptr", hwnd, "Ptr", rgn, "Int", true)
}

; taller ListView rows: a 1px-wide image list sets the row height
RowHeight(lv, h) {
    il := DllCall("comctl32\ImageList_Create", "Int", 1, "Int", Round(h * A_ScreenDPI / 96), "UInt", 0x21, "Int", 1, "Int", 1, "Ptr")
    SendMessage(0x1003, 1, il, lv)              ; LVM_SETIMAGELIST, LVSIL_SMALL
}

SetWindowTheme(hwnd, name) => DllCall("uxtheme\SetWindowTheme", "Ptr", hwnd, "Str", name, "Ptr", 0)

DarkTitle(hwnd) {
    if VerCompare(A_OSVersion, "10.0.17763") < 0
        return
    attr := VerCompare(A_OSVersion, "10.0.18985") >= 0 ? 20 : 19      ; DWMWA_USE_IMMERSIVE_DARK_MODE
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "Int", attr, "Int*", 1, "Int", 4)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "Int", 35, "UInt*", BGR(T.bg), "Int", 4)   ; Win11 caption colour
}

; dark tray / context menus
DarkMenus() {
    if VerCompare(A_OSVersion, "10.0.18362") < 0
        return
    ux := DllCall("LoadLibrary", "Str", "uxtheme", "Ptr")
    DllCall(DllCall("GetProcAddress", "Ptr", ux, "Ptr", 135, "Ptr"), "Int", 2)    ; SetPreferredAppMode(ForceDark)
    DllCall(DllCall("GetProcAddress", "Ptr", ux, "Ptr", 136, "Ptr"))              ; FlushMenuThemes
}

BGR(hex) {
    n := Integer("0x" hex)
    return ((n & 0xFF) << 16) | (n & 0xFF00) | (n >> 16)
}

HasVal(arr, v) => IndexOf(arr, v) > 0

IndexOf(arr, v) {
    for i, x in arr
        if (x = v)
            return i
    return 0
}

Join(arr, sep := "|") {
    s := ""
    for v in arr
        s .= (A_Index > 1 ? sep : "") v
    return s
}
