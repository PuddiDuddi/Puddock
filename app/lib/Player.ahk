#Requires AutoHotkey v2.0
; Puddock — the player window: video, divider, embedded chat (part of puddock.ahk, included from there)

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
        this.reloading := false, this.reconnects := 0, this.streamAt := 0, this.portNonce := ""

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
        ; Left clicks on the video / the chat: both are windows of other processes inside ours, so
        ; the click itself never reaches us. Raw input tells us about it with an ordinary posted
        ; message — unlike a mouse hook (~LButton), which sits in the path of every click on the
        ; whole system and makes the mouse stutter whenever this script is busy.
        this.clickFn := ObjBindMethod(this, "OnClick")
        OnMessage(0xFF,  ObjBindMethod(this, "OnRawInput"))     ; WM_INPUT
        rid := Buffer(8 + A_PtrSize, 0)                         ; RAWINPUTDEVICE: generic desktop / mouse
        NumPut("UShort", 1, "UShort", 2, "UInt", 0x100, "Ptr", g.Hwnd, rid)   ; RIDEV_INPUTSINK
        DllCall("RegisterRawInputDevices", "Ptr", rid, "UInt", 1, "UInt", rid.Size)
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
        this.secretAt := this.streamAt := A_TickCount
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
        this.tickSlow := false
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
                if WinActive(this.g.Hwnd) && !this.ChatHasFocus()   ; don't cut off someone typing in chat
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
            else if this.ShouldReconnect()
                return this.ReloadStream()            ; offline by now? then the retry reports it and exits
            ExitApp
        }
        ; Starting up needs a quick eye (the token pipe, mpv's window showing up). Once the video
        ; plays, only "has streamlink ended?" and the window guards are left: look less often.
        ; (AutoHotkey has one thread, so a process handle can't be waited on without looking.)
        if this.videoUp && !this.secret && !this.tickSlow {
            this.tickSlow := true
            SetTimer(this.tickFn, 300)
        }
    }

    ; streamlink ended while the video was playing. "Player closed" in its log: the user quit mpv,
    ; so we close too. Only "Stream ended": the stream broke off (network hiccup, or the broadcast
    ; is over) — connect again, 3 times in a row at most (a run of a minute or more starts the
    ; count again). Neither line (e.g. the user's own --loglevel hides them): close, as before.
    ShouldReconnect() {
        try log := FileRead(this.log)
        catch
            return false
        if !InStr(log, "Stream ended") || InStr(log, "Player closed")
            return false
        if (A_TickCount - this.streamAt >= 60000)
            this.reconnects := 0
        return ++this.reconnects <= 3
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
        this.portNonce := nonce                          ; names the extension's port for this chat (PortSend)
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
            if (cls = "Chrome_WidgetWin_1" || cls = "MozillaWindowClass") && HasVal(browsers, exe) && this.Embed(h)
                return
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
        ; A NEW window of the browser we just started whose title is the chat's (IsChatTitle). (Never
        ; just "any new window": that could be one the user opened, which we'd swallow and later close.)
        for h in WinGetList("ahk_exe ^" RegExReplace(this.browserExe, "\.", "\.") "$") {
            if HasVal(this.before, h)
                continue
            try {
                if WinGetClass(h) != "Chrome_WidgetWin_1" || (title := WinGetTitle(h)) = ""
                    continue
            } catch
                continue
            if IsChatTitle(title, this.ch) && this.Embed(h)
                return
        }
        if A_TickCount - this.chatT0 > 15000
            this.ChatFail("Couldn't catch the browser's chat window. Playing video only.")
    }

    ; -> true if the window is ours now. The browser's window can vanish (or refuse) at any step:
    ; then nothing is taken over and the search goes on — another window, or giving up after 15 s.
    Embed(h) {
        try {
            style := WinGetStyle(h)
            WinSetStyle("-0xC40000",   h)      ; no caption / frame
            WinSetStyle("-0x80000000", h)      ; -WS_POPUP
            WinSetStyle("+0x40000000", h)      ; +WS_CHILD (drops off the taskbar)
        } catch
            return false
        if !DllCall("SetParent", "Ptr", h, "Ptr", this.host.Hwnd, "Ptr") && !DllCall("IsChild", "Ptr", this.host.Hwnd, "Ptr", h) {
            try WinSetStyle(style, h)          ; not ours: give the browser its frame back
            return false
        }
        SetTimer(this.chatFn, 0)
        this.chatHwnd := h
        this.Relayout()
        this.UpdateMenus()
        ; the browser re-lays out its frame a moment after the style change: measure again
        for ms in [300, 1000, 3000]
            SetTimer(ObjBindMethod(this, "Relayout"), -ms)
        return true
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
        if this.embedded && this.mpvHwnd && DllCall("IsWindow", "Ptr", this.mpvHwnd) {
            try ControlFocus(this.mpvHwnd)
            this.ChatActivation(false)                ; the chat's input box stops looking focused
        }
    }

    OnRawInput(wParam, lParam, *) {
        static hdr := A_PtrSize = 8 ? 24 : 16                   ; RAWINPUTHEADER
        buf := Buffer(hdr + 32, 0), size := buf.Size            ; RAWINPUT holding a RAWMOUSE (24 bytes)
        if DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", buf, "UInt*", &size   ; RID_INPUT
                 , "UInt", hdr, "UInt") = 0xFFFFFFFF
            return
        if NumGet(buf, 0, "UInt") = 0 && (NumGet(buf, hdr + 4, "UShort") & 0x1)   ; RIM_TYPEMOUSE, RI_MOUSE_LEFT_BUTTON_DOWN
            SetTimer(this.clickFn, -1)                          ; outside this message
    }

    OnClick() {
        if this.MouseOverVideo()
            this.FocusVideo()             ; embedded mode: click on the video -> keyboard goes to mpv
        else if this.MouseOverChat()
            this.FocusChat()              ; click on the chat -> keyboard goes to the chat (not mpv)
    }

    MouseOverVideo() {
        if !this.embedded || !this.mpvHwnd
            return false
        MouseGetPos(, , &win, &ctl, 2)
        return win = this.g.Hwnd && (ctl = this.mpvHwnd || ctl = this.vg.Hwnd)
    }

    ; The chat is a child window of another process too: a click on it doesn't take the keyboard
    ; away from mpv (both share our window's focus), so hand it over the same way.
    FocusChat() {
        if !this.chatHwnd || !DllCall("IsWindow", "Ptr", this.chatHwnd)
            return
        if !this.ChatHasFocus()
            try ControlFocus(this.chatHwnd)
        this.ChatActivateAfterClick()
    }

    ; The browser marks itself inactive on every click into it (WM_MOUSEACTIVATE on a child
    ; window), whenever we hear about the click. Activate it when the click is over.
    ChatActivateAfterClick() {
        if !this.HasOwnProp("chatActFn")
            this.chatActFn := ObjBindMethod(this, "ChatActivateAfterClick")
        if GetKeyState("LButton", "P") {
            SetTimer(this.chatActFn, -30)
            return
        }
        SetTimer(this.chatActFn, 0)
        if WinActive(this.g.Hwnd)                    ; not if the user already went to another window
            SetTimer(ObjBindMethod(this, "ChatActivation", true), -30)   ; let the browser finish the click
    }

    ; The browser decides if its page has focus (caret, highlighted "Send a message" box) from
    ; WM_ACTIVATE only, and it handles that message only for a top-level window (no WS_CHILD).
    ; As our child the chat never gets deactivated, so it keeps looking focused after the user
    ; clicks another window. Tell it ourselves: drop WS_CHILD for the time of one synchronous
    ; message (with a timeout: a hung browser can't block us), then put it back.
    ChatActivation(active) {
        h := this.chatHwnd
        if !h || !DllCall("IsWindow", "Ptr", h)
            return
        style := DllCall("GetWindowLongPtr", "Ptr", h, "Int", -16, "Ptr")          ; GWL_STYLE
        if !(style & 0x40000000)                                                    ; not ours any more
            return
        ; The browser goes inactive by itself on clicks into it, so WA_ACTIVE is always sent again.
        if !active && this.HasOwnProp("chatActive") && !this.chatActive             ; already told it
            return
        this.chatActive := active
        DllCall("SetWindowLongPtr", "Ptr", h, "Int", -16, "Ptr", style & ~0x40000000)
        DllCall("SendMessageTimeout", "Ptr", h, "UInt", 0x6, "Ptr", active ? 1 : 0, "Ptr", 0  ; WM_ACTIVATE
              , "UInt", 0x2, "UInt", 500, "Ptr*", 0)                                ; SMTO_ABORTIFHUNG
        DllCall("SetWindowLongPtr", "Ptr", h, "Int", -16, "Ptr", style)
    }

    ; Our window lost activation. The browser can take it itself when we tell it it's active
    ; (it then "activates" its own window, which is our child): that is not the user leaving,
    ; so take the activation back instead of telling the chat it's inactive (else: a loop).
    OnDeactivated() {
        fg := DllCall("GetForegroundWindow", "Ptr")
        if (fg = this.g.Hwnd)
            return
        if this.chatHwnd && (fg = this.chatHwnd || DllCall("IsChild", "Ptr", this.chatHwnd, "Ptr", fg)
                             || DllCall("GetAncestor", "Ptr", fg, "UInt", 2, "Ptr") = this.g.Hwnd) {
            try WinActivate(this.g.Hwnd)
            return
        }
        this.ChatActivation(false)
    }

    ; Activated with the keyboard (Alt+Tab, taskbar): if the focus came back to the chat, wake it up.
    ChatFocusBack() {
        if this.ChatHasFocus()
            this.ChatActivation(true)
    }

    MouseOverChat() {
        if !this.chatHwnd || !this.chatVisible || !DllCall("IsWindowVisible", "Ptr", this.host.Hwnd)
            return false
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my, &win)
        r := WinRect(this.host.Hwnd)                  ; the visible part of the chat
        return win = this.g.Hwnd && mx >= r[1] && mx < r[3] && my >= r[2] && my < r[4]
    }

    ChatHasFocus() {
        f := FocusOfForeground()
        return this.chatHwnd && f && (f = this.chatHwnd || DllCall("IsChild", "Ptr", this.chatHwnd, "Ptr", f))
    }

    OnActivate(wParam, lParam, msg, hwnd) {
        if (hwnd != this.g.Hwnd)
            return
        if !(wParam & 0xFFFF) {                       ; another window took over
            SetTimer(ObjBindMethod(this, "OnDeactivated"), -1)          ; outside this message
            return
        }
        if this.MouseOverVideo()
            SetTimer(ObjBindMethod(this, "FocusVideo"), -30)
        else if this.MouseOverChat()
            SetTimer(ObjBindMethod(this, "FocusChat"), -30)
        else
            SetTimer(ObjBindMethod(this, "ChatFocusBack"), -30)
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
        out := APP " " VERSION "`n"
             . "Mode: " (this.embedded ? "Embedded (--wid)" : "Separate window") "`n"
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
        if this.HasOwnProp("bar")
            this.bar.Wake()               ; it sleeps while another program is in front
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
        A_IconTip := this.ch " · " APP " " VERSION
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
        m.Add(APP " " VERSION, (*) => 0)
        m.Disable(APP " " VERSION)                   ; shows which build is running
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
        this.bar.Wake()
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
    ; Send types into whatever has the focus: if the chat didn't get it (another window came up,
    ; the browser is busy), the keys would land in mpv or another app. Check, try once more, give up.
    ChatKeys(keys, retry := true) {
        if !this.chatHwnd || !DllCall("IsWindow", "Ptr", this.chatHwnd)
            return
        if GetKeyState("LButton", "P") || GetKeyState("RButton", "P") {
            SetTimer(() => this.ChatKeys(keys, retry), -30)
            return
        }
        if !this.chatVisible
            this.ToggleChat()
        try WinActivate(this.g.Hwnd)
        try ControlFocus(this.chatHwnd)
        this.ChatActivation(true)
        Sleep(50)
        if !(WinActive(this.g.Hwnd) && this.ChatHasFocus()) {
            if retry
                SetTimer(() => this.ChatKeys(keys, false), -150)
            return
        }
        Send(keys)
    }

    ; Done by the extension inside the chat page (chat.js): settings gear / page zoom / reload.
    ; Asked for through the extension's port when there is one (no focus juggling, no keystrokes),
    ; otherwise typed into the chat as the page's own shortcuts. (Not the browser's F5: sent keys
    ; reach the page, but not the browser's own shortcuts while its window is embedded.)
    ChatDo(action, keys) {
        if !this.chatHwnd
            return
        if !this.chatVisible
            this.ToggleChat()
        if !this.PortSend(action)
            this.ChatKeys(keys)
    }

    ChatSettings() => this.ChatDo("settings", "!+s")
    ChatZoom(dir) => this.ChatDo(dir = "in" ? "zoomIn" : dir = "out" ? "zoomOut" : "zoomReset"
                               , dir = "in" ? "!+{Up}" : dir = "out" ? "!+{Down}" : "!+0")
    ReloadChat() => this.ChatDo("reload", "!+r")

    ; While the chat is open, the extension keeps a native-messaging port open: one more copy of
    ; this program, as the browser's helper, with the hidden window "puddock-port-<nonce>"
    ; (NativeHost, "attach"). Hand it one word; it passes it on to the extension, which does it in
    ; the chat page. -> true if the helper took it.
    PortSend(action) {
        if (this.portNonce = "")
            return false
        prev := A_DetectHiddenWindows
        DetectHiddenWindows(true)
        h := WinExist("^" PORT_TITLE this.portNonce "$ ahk_class ^AutoHotkey$")
        DetectHiddenWindows(prev)
        if !h
            return false
        cds := Buffer(A_PtrSize * 3, 0), res := 0                ; COPYDATASTRUCT: dwData, cbData, lpData
        NumPut("UInt", StrLen(action) * 2, cds, A_PtrSize), NumPut("Ptr", StrPtr(action), cds, A_PtrSize * 2)
        return DllCall("SendMessageTimeout", "Ptr", h, "UInt", 0x4A, "Ptr", this.g.Hwnd, "Ptr", cds   ; WM_COPYDATA
                     , "UInt", 0x2, "UInt", 300, "UPtr*", &res) && res = 1      ; SMTO_ABORTIFHUNG
    }

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

