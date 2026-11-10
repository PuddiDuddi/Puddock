#Requires AutoHotkey v2.0
; Puddock — the launcher window: channels, settings, account, setup (part of puddock.ahk, included from there)

; ===========================================================================
;  Launcher: a narrow sidebar (pages, account, readiness) and the page next to it.
;
;  Layout: nothing has a fixed place. Every control is created at 0,0 and put where it belongs
;  by Layout(), from the window's current size — so the window can be resized: the channel list
;  grows with it, text fields grow up to a comfortable width. Positions are written in 96-dpi
;  pixels on a 4 px grid and scaled by S (the window itself is -DPIScale, like the player).
;
;  Look: one accent (Twitch purple) per page, on the one thing the page is for; everything else
;  is the neutral ramp. The line at the bottom describes whatever the mouse is over.
; ===========================================================================
class Launcher {
    static W := 840, H := 700, MINW := 800, MINH := 680, SIDE := 176, PAD := 28

    __New(page) {
        this.cfg := LoadConfig()
        s := this.S := A_ScreenDPI / 96
        this.pages := Map("Watch", [], "Settings", [], "Account", [], "Setup", [])
        this.btns := Map(), this.tips := Map(), this.fields := []
        this.hot := 0, this.helpAt := 0, this.cur := "", this.page := ""
        this.rows := [], this.lastRaw := "", this.filling := false
        this.flashUntil := 0, this.descText := "", this.setupOk := true
        this.hoverFn := ObjBindMethod(this, "HoverCheck")
        this.restoreFn := ObjBindMethod(this, "RestoreDesc")

        g := this.g := Gui("+Resize -DPIScale +MinSize" Round(Launcher.MINW * s) "x" Round(Launcher.MINH * s), APP)
        g.BackColor := T.bg
        g.MarginX := g.MarginY := 0
        g.SetFont("s10 c" T.text, FONT)
        g.OnEvent("Close", (*) => this.Quit())
        g.OnEvent("Escape", (*) => this.Quit())
        DarkTitle(g.Hwnd)

        this.BuildSidebar()
        this.BuildWatch()
        this.BuildSettings()
        this.BuildAccount()
        this.BuildSetup()
        this.cur := ""
        this.rule := g.AddText("x0 y0 w10 h1 Background" T.line)
        this.desc := g.AddText("x0 y0 w10 h10 c" T.dim, "")
        this.desc.SetFont("s9")

        g.OnEvent("Size", (gui, mm, w, h) => this.Layout(mm, w, h))
        OnMessage(0x200, ObjBindMethod(this, "OnMouseMove"))   ; WM_MOUSEMOVE  -> hover, description
        OnMessage(0x20,  ObjBindMethod(this, "OnSetCursor"))   ; WM_SETCURSOR  -> hand cursor
        OnMessage(0x6,   ObjBindMethod(this, "OnActivate"))    ; WM_ACTIVATE   -> refresh list

        tray := A_TrayMenu                                         ; plain app menu, nothing AutoHotkey-specific
        tray.Delete()
        tray.Add("Show " APP, (*) => BringToFront(this.g.Hwnd))
        tray.Default := "Show " APP
        tray.Add()
        tray.Add("Settings…", (*) => (BringToFront(this.g.Hwnd), this.ShowPage("Settings")))
        tray.Add()
        tray.Add("Exit", (*) => this.Quit())
        tray.ClickCount := 1
        A_IconTip := APP " " VERSION

        this.page := page                                          ; Layout (first Size event) fills its list
        for p, list in this.pages                                  ; before the window shows: one page, not four on top of each other
            for c in list
                SetVis(c, p = page)
        g.Show(this.InitialSize())
        this.ShowPage(page)
    }

    InitialSize() {
        s := this.S, w := Launcher.W, h := Launcher.H
        sw := IniRead(INI_FILE, "State", "LauncherW", ""), sh := IniRead(INI_FILE, "State", "LauncherH", "")
        if IsInteger(sw) && IsInteger(sh) && sw >= Launcher.MINW && sh >= Launcher.MINH
            w := Min(sw, Floor(A_ScreenWidth / s) - 40), h := Min(sh, Floor(A_ScreenHeight / s) - 80)
        return "w" Round(Max(w, Launcher.MINW) * s) " h" Round(Max(h, Launcher.MINH) * s)
    }

    Quit() {
        try {
            if (WinGetMinMax(this.g.Hwnd) = 0) {                   ; not while maximized / minimized
                this.g.GetClientPos(, , &w, &h)
                IniWrite(Round(w / this.S), INI_FILE, "State", "LauncherW")
                IniWrite(Round(h / this.S), INI_FILE, "State", "LauncherH")
            }
        }
        ExitApp()
    }

    ; ---------- sidebar ----------
    BuildSidebar() {
        s := this.S
        sb := this.sb := Gui("-Caption -DPIScale +Parent" this.g.Hwnd)
        sb.BackColor := T.panel
        sb.MarginX := sb.MarginY := 0
        sb.SetFont("s10 c" T.text, FONT)
        logoSrc := A_IsCompiled ? A_ScriptFullPath : ICON          ; the app icon (embedded in the exe)
        if FileExist(logoSrc)
            sb.AddPicture(Format("x{} y{} w{} h{} Icon1", Round(20 * s), Round(24 * s), Round(32 * s), Round(32 * s)), logoSrc)
        this.name := sb.AddText("x0 y0 w10 h10 +0x200", APP)
        this.name.SetFont("s12")
        this.ver := sb.AddText("x0 y0 w10 h10 +0x200 c" T.dim, VERSION)
        this.ver.SetFont("s9")

        this.bar := sb.AddText("x0 y0 w3 h10 Background" T.accent)   ; marks the open page
        this.nav := Map()
        for i, n in ["Watch", "Settings", "Account", "Setup"]
            this.nav[n] := {c: this.Button("  " n, this.ShowPage.Bind(this, n), "nav", sb), y: 96 + (i - 1) * 36}

        this.acctDot := this.Dot(sb)
        this.acctHdr := sb.AddText("x0 y0 w10 h10 +0x200 c" T.muted, "")
        this.acctHdr.SetFont("s9")
        this.acctHdr.OnEvent("Click", (*) => this.ShowPage("Account"))
        this.state := sb.AddText("x0 y0 w10 h10 +0x200 c" T.dim, "")
        this.state.SetFont("s9")
        this.state.OnEvent("Click", (*) => !this.setupOk && this.ShowPage("Setup"))
        sb.Show("x0 y0 w10 h10 NA")
    }

    ; ---------- pages ----------
    BuildWatch() {
        this.cur := "Watch"
        this.chan := Field(this, "channel", "", "twitch.tv/")
        this.Help(this.chan, "A channel name or a whole twitch.tv link. Enter plays it")
        this.watchBtn := this.Button("Watch", (*) => this.Watch(), "accent")
        this.listLbl := this.Label("Channels", "", T.dim)
        this.favBtn := this.Button("Favorite", (*) => this.ToggleFav(), "plain")
        this.Help(this.favBtn, "Keeps the selected channel at the top of the list, marked with *. Again: back to the recent ones")
        this.remBtn := this.Button("Remove", (*) => this.RemoveRow(), "plain")
        this.Help(this.remBtn, "Takes the selected channel off the list")

        ; one column of fixed-width text: the name on the left, "last watched" pushed to the right
        ; edge with spaces (FillList) — the page's own background, no box, no grid
        lv := this.lv := this.Add("ListView", "x0 y0 w100 h100 -Hdr -Multi -E0x200 +LV0x10000 c" T.text
                                 . " Background" T.bg, ["Channel"])
        SetWindowTheme(lv.Hwnd, "DarkMode_Explorer")
        RowHeight(lv, 32)
        lv.OnEvent("DoubleClick", (lv, row) => row && this.Launch(this.rows[row]))
        lv.OnEvent("ItemSelect", (lv, row, sel) => sel && !this.filling && this.rows[row] != "" && (this.chan.Value := this.rows[row]))
    }

    BuildSettings() {
        this.cur := "Settings"
        f := this.f := Map()
        this.defBtn := this.Button("Defaults", (*) => this.Fill(DEFAULTS))
        this.Help(this.defBtn, "Puts every setting on this page back to what Puddock starts with. Nothing is stored until you press Save")
        this.saveBtn := this.Button("Save", (*) => this.Save(), "accent")
        this.Help(this.saveBtn, "Stores the settings. A player that is already open picks them up the next time its stream (re)starts")
        this.grp := [this.Label("Player", "", T.dim), this.Label("Chat", "", T.dim), this.Label("Window", "", T.dim)]

        h := "Which stream quality to ask for. If the channel doesn't offer it, the best one it has is played"
        f["Quality"] := Segment(this, ["best", "1080p60", "720p60", "480p", "360p", "audio_only"]
                                    , ["Best", "1080p60", "720p60", "480p", "360p", "Audio"], 66, h)
        player := [Row(this.Label("Quality", h), (x, y, w) => this.Put(f["Quality"], x, y, w, 32))]

        h := "Keeps the last minutes in memory, so the arrow keys in mpv can go back in a live stream. "
           . "30 minutes take about 1.8 GB of RAM. F6 in the player jumps back to live"
        f["Rewind"] := Segment(this, ["0", "5", "15", "30"], ["Off", "5 min", "15 min", "30 min"], 72, h)
        player.Push(Row(this.Label("Rewind", h), (x, y, w) => this.Put(f["Rewind"], x, y, w, 32)))

        h := "Embedded draws mpv inside Puddock's window. Separate window keeps mpv a window of its own, glued "
           . "in place: try it if the embedded video stays black or doesn't react to the mouse"
        f["VideoMode"] := Segment(this, ["Embedded", "Window"], ["Embedded", "Separate window"], 150, h)
        player.Push(Row(this.Label("Video mode", h), (x, y, w) => this.Put(f["VideoMode"], x, y, w, 32)))

        h := "Extra command-line options for mpv, written the way you would type them. Used the next time a stream starts"
        f["MpvArgs"] := Field(this)
        this.Help(f["MpvArgs"], h)
        player.Push(Row(this.Label("mpv arguments", h), (x, y, w) => this.Put(f["MpvArgs"], x, y, w, 32)))

        h := "Extra command-line options for streamlink, for example --hls-live-edge 2"
        f["StreamlinkArgs"] := Field(this, "none")
        this.Help(f["StreamlinkArgs"], h)
        player.Push(Row(this.Label("Streamlink arguments", h), (x, y, w) => this.Put(f["StreamlinkArgs"], x, y, w, 32)))

        f["LowLatency"] := Toggle(this, "Low latency", "Plays closer to live: streamlink's low-latency mode and mpv's "
            . "low-latency profile. Turn it off if the video stutters on a weak connection")
        player.Push(Row(0, (x, y, w) => this.Put(f["LowLatency"], x, y, 228, 32)))

        h := "The side of the video the chat sits on. Its width can also be changed by dragging the divider in the player"
        f["ChatSide"] := Segment(this, ["Left", "Right"], ["Left", "Right"], 72, h)
        chat := [Row(this.Label("Side", h), (x, y, w) => this.Put(f["ChatSide"], x, y, w, 32))]

        h := "Width of the chat in pixels, from 200 to 1200"
        f["ChatWidth"] := Field(this)
        this.Help(f["ChatWidth"], h)
        chat.Push(Row(this.Label("Width (px)", h), (x, y, w) => this.Put(f["ChatWidth"], x, y, 80, 32)))

        h := "Only used when the Puddock extension isn't in your browser: the chat then opens as an app window of this "
           . "browser. Empty: your default browser if it is Chromium-based, else Brave, Chrome, Edge, Vivaldi or Opera"
        f["BrowserPath"] := Field(this, "automatic")
        this.Help(f["BrowserPath"], h)
        browse := this.Button("Browse…", (*) => this.Browse("BrowserPath", "browser"))
        this.Help(browse, h)
        chat.Push(Row(this.Label("Fallback browser", h)
            , (x, y, w) => (this.Put(f["BrowserPath"], x, y, w - 104, 32), this.Put(browse, x + w - 96, y, 96, 32))))

        f["ChatDark"] := Toggle(this, "Dark theme", "Opens Twitch's popout chat in its dark theme")
        f["ChatInFullscreen"] := Toggle(this, "Keep chat in fullscreen", "On: the chat stays next to the video in "
            . "fullscreen. Off: fullscreen shows the video alone, and F9 brings the chat back")
        chat.Push(Row(0, (x, y, w) => (this.Put(f["ChatDark"], x, y, 228, 32), this.Put(f["ChatInFullscreen"], x + 236, y, 228, 32))))

        h := "Size of the player's window in pixels when it opens for the first time, and every time while "
           . "“Remember position” is off"
        f["WinW"] := Field(this), f["WinH"] := Field(this)
        this.Help(f["WinW"], h), this.Help(f["WinH"], h)
        times := this.Add("Text", "x0 y0 w10 h10 +0x200 Center c" T.dim, "×")
        win := [Row(this.Label("Size (px)", h), (x, y, w) => (this.Put(f["WinW"], x, y, 80, 32)
            , this.Put(times, x + 80, y, 24, 32), this.Put(f["WinH"], x + 104, y, 80, 32)))]

        f["RememberPos"] := Toggle(this, "Remember position", "Opens the player where you closed it last time, at the same size")
        f["StartFullscreen"] := Toggle(this, "Start fullscreen", "The player opens in fullscreen. F11 or Esc leaves it")
        win.Push(Row(0, (x, y, w) => (this.Put(f["RememberPos"], x, y, 228, 32), this.Put(f["StartFullscreen"], x + 236, y, 228, 32))))
        f["AlwaysOnTop"] := Toggle(this, "Always on top", "The player stays above other windows. F8 switches it while you watch")
        f["CloseLauncher"] := Toggle(this, "Close after Watch", "Closes this launcher as soon as a channel starts playing")
        win.Push(Row(0, (x, y, w) => (this.Put(f["AlwaysOnTop"], x, y, 228, 32), this.Put(f["CloseLauncher"], x + 236, y, 228, 32))))

        this.groups := [player, chat, win]
        this.Fill(this.cfg)
    }

    BuildAccount() {
        this.cur := "Account"
        this.acctBig := this.Dot()
        this.acctTxt := this.Add("Text", "x0 y0 w10 h10 +0x200", "")
        this.acctSub := this.Add("Text", "x0 y0 w10 h10 +0x200 c" T.dim, "")
        this.acctSub.SetFont("s9")
        this.outBtn := this.Button("Log out", (*) => this.LogoutUI(), "plain")
        this.Help(this.outBtn, "Removes the saved login from Windows Credential Manager. Streams then play anonymously, with ads")

        h := "The extension asks for cookie access at that moment, reads only twitch.tv's login cookie, hands it to "
           . "this app over the private browser connection, and gives the access back"
        this.conLbl := this.Label("Connect in your browser", "", T.dim)
        this.conTxt := this.Label("Opens the extension's options. Press “Connect Twitch account” there", h)
        this.conBtn := this.Button("Connect in browser", (*) => this.ConnectInBrowser(), "accent")
        this.Help(this.conBtn, h)

        h := "Where to find it: twitch.tv in your browser, F12, Application, Cookies, https://www.twitch.tv, the value "
           . "of auth-token. Kept in Windows Credential Manager: never shown again, never on a command line"
        this.tokLbl := this.Label("Or paste a token", h, T.dim)
        this.tokenEd := Field(this, "auth-token", "Password")
        this.Help(this.tokenEd, h)
        this.tokSave := this.Button("Save", (*) => this.SaveTokenUI())
        this.Help(this.tokSave, "Asks Twitch whether the pasted token is valid, then stores it in place of the old one")
        this.tokTest := this.Button("Test", (*) => this.TestTokenUI())
        this.Help(this.tokTest, "Asks Twitch whether the token is still valid: the pasted one, or else the saved one, without showing it")
    }

    UpdateAccount(*) {
        on := LoadToken() != ""
        login := IniRead(INI_FILE, "Account", "Login", ""), checked := IniRead(INI_FILE, "Account", "Checked", "")
        try checked := checked != "" ? "Checked " FormatTime(checked, "yyyy-MM-dd") : ""
        catch
            checked := ""
        this.acctTxt.Text := on ? "Logged in as " (login != "" ? login : "(unverified)") : "Not logged in"
        this.acctSub.Text := on ? checked : "Streams play with ads"
        this.SetDot(this.acctBig, on ? T.ok : T.dim)
        this.acctHdr.Text := on ? (login != "" ? login : "logged in") : "not logged in"
        this.acctHdr.SetFont("c" (on ? T.muted : T.dim))
        this.SetDot(this.acctDot, on ? T.ok : T.dim)
        SetVis(this.outBtn, on && this.page = "Account")
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
            return this.Flash(Trim(this.tokenEd.Value) = "" ? "Nothing to save: paste a token first" : "That doesn't look like a Twitch token", T.warn)
        info := this.CheckToken(tok)
        if (info = 0)
            return this.Flash("Twitch rejected this token. Log in to twitch.tv again and copy a fresh one", T.warn)
        SaveToken(tok, info ? info.login : "")
        this.tokenEd.Value := ""                      ; write-only: the field never holds a saved token
        this.UpdateAccount()
        if !info
            this.Flash("Saved, but Twitch couldn't be reached to verify it", T.warn)
        else if (info.clientId != WEB_CLIENT_ID)
            this.Flash("Saved, but it isn't a twitch.tv browser token: streamlink may ignore it", T.warn)
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
            this.Flash("Twitch couldn't be reached", T.warn)
        else if (info = 0)
            this.Flash("Token rejected: it expired, or you logged out on twitch.tv", T.warn)
        else {
            if (typed = "")
                IniWrite(info.login, INI_FILE, "Account", "Login"), IniWrite(A_Now, INI_FILE, "Account", "Checked")
            this.UpdateAccount()
            this.Flash("Valid: " info.login ", expires in " (info.expires ? info.expires // 86400 " days" : "never")
                     . (info.clientId != WEB_CLIENT_ID ? " (not a twitch.tv browser token)" : ""), T.ok)
        }
    }

    LogoutUI() {
        ClearToken()
        this.tokenEd.Value := ""
        this.UpdateAccount()
        this.Flash("Logged out. Streams play anonymously now", T.muted)
    }

    ; Setup: everything Puddock needs, each with its state and a way to fix it
    BuildSetup() {
        this.cur := "Setup"
        this.srow := Map(), this.sorder := ["streamlink", "mpv", "ext", "host"]
        this.SetupRow("streamlink", "streamlink", "Fetches the stream from Twitch. Install asks winget (which shows what it does); "
            . "Browse points to a streamlink.exe you already have"
            , "Install", this.InstallTool.Bind(this, "streamlink"), "Browse…", this.BrowseTool.Bind(this, "streamlink"))
        this.SetupRow("mpv", "mpv", "Plays the video. Install asks winget; Browse points to an mpv.exe you already have"
            , "Install", this.InstallTool.Bind(this, "mpv"), "Browse…", this.BrowseTool.Bind(this, "mpv"))
        this.SetupRow("ext", "Browser extension", "Load it once: open chrome://extensions (the address is copied for you), turn on "
            . "Developer mode, press Load unpacked and pick the folder that opens. The chat then opens in your own browser, with your 7TV / BTTV"
            , "Open folder", (*) => this.GetExtension())
        this.SetupRow("host", "Browser connection", "Registers Puddock with your browsers (native messaging, this Windows user only) "
            . "so that its extension, and no web page, can talk to this app"
            , "Register", (*) => (RegisterNativeHost(), this.UpdateStatus()), "Remove", (*) => (UnregisterNativeHost(), this.UpdateStatus()))

        this.shortLbl := this.Label("Shortcuts", "", T.dim)
        desk := this.deskBtn := this.Button("Desktop", (*) => (MakeShortcut(A_Desktop), FlashText(desk, "Created")))
        this.Help(desk, "Puts a Puddock shortcut on the desktop")
        start := this.startBtn := this.Button("Start menu", (*) => (MakeShortcut(A_Programs), FlashText(start, "Created")))
        this.Help(start, "Puts a Puddock shortcut into the Start menu")
    }

    SetupRow(key, title, help, t1, cb1, t2 := "", cb2 := 0) {
        r := {name: this.Label(title, help, T.text), dot: this.Dot(), status: this.Label("", help)
            , hint: this.Add("Text", "x0 y0 w10 h10 +0x200 +0x100 +0x8000 c" T.dim, "")     ; SS_PATHELLIPSIS
            , b1: this.Button(t1, cb1), b2: t2 = "" ? 0 : this.Button(t2, cb2)}
        r.hint.SetFont("s9")
        this.Help(r.hint, help), this.Help(r.b1, help)
        if r.b2
            this.Help(r.b2, help)
        this.srow[key] := r
    }

    InstallTool(key, *) {
        id := key = "streamlink" ? STREAMLINK_WINGET : MPV_WINGET
        this.Flash("Asking winget for " id "…", T.muted)
        if !(pid := WingetInstall(id)) {
            Run(key = "streamlink" ? "https://streamlink.github.io/install.html" : "https://mpv.io/installation/")
            return this.Flash("winget can't install " key " here. Its download page is open instead", T.warn)
        }
        this.Flash("Installing " key " with winget: follow the console window", T.muted)
        this.installPid := pid
        SetTimer(this.installFn := ObjBindMethod(this, "InstallDone", key), 1000)
    }

    InstallDone(key) {
        if ProcessExist(this.installPid)
            return
        SetTimer(this.installFn, 0)
        this.UpdateStatus()
        found := key = "streamlink" ? FindTools(LoadConfig()).streamlink : FindTools(LoadConfig()).mpv
        this.Flash(found != "" ? key " is ready" : key " still not found. Try Browse…", found != "" ? T.ok : T.warn)
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
        this.Flash("chrome://extensions is copied. There: Developer mode, Load unpacked, pick the folder that just opened", T.muted)
    }

    ; Opens the extension's options in the user's browser; they press "Connect" there
    ; (the extension asks for cookie access only at that moment).
    ConnectInBrowser() {
        RememberNonce("Connect", nonce := RandomHex(16))       ; the extension checks it with us first
        Run("https://www.twitch.tv/?puddock=connect-" nonce)
        this.Flash("Your browser opens Puddock's options. Press “Connect Twitch account” there", T.muted)
    }

    ShowPage(name, *) {
        ; Swap pages with drawing paused and repaint the whole window once at the end: no
        ; flicker, and no pixels of the old page left behind.
        DllCall("SendMessage", "Ptr", this.g.Hwnd, "UInt", 0xB, "Ptr", 0, "Ptr", 0)   ; WM_SETREDRAW off
        this.page := name
        for p, list in this.pages
            for c in list
                SetVis(c, p = name)
        for n, o in this.nav
            this.Paint(o.c, n = name ? T.input : T.panel, T.hover, n = name ? T.text : T.muted)
        this.Put(this.bar, 0, this.nav[name].y + 6, 3, 20)
        this.UpdateAccount()                                    ; also: "Log out" only while logged in
        DllCall("SendMessage", "Ptr", this.g.Hwnd, "UInt", 0xB, "Ptr", 1, "Ptr", 0)   ; WM_SETREDRAW on
        DllCall("RedrawWindow", "Ptr", this.g.Hwnd, "Ptr", 0, "Ptr", 0
              , "UInt", 0x585)                                 ; INVALIDATE|ERASE|ALLCHILDREN|UPDATENOW|FRAME
        this.helpAt := 0
        this.SetDesc(this.PageHint(name))
        if (name = "Watch") {
            this.RefreshList(true)
            try this.chan.Focus()
        }
        for fld in this.fields                                  ; the page's first field gets the focus with all of its
            fld.Home()                                          ; text selected, scrolled to its end: show the start instead
        this.UpdateStatus()
    }

    PageHint(name) {
        switch name {
            case "Watch": return "Enter or a double-click plays the channel. While you watch: F11 fullscreen, F9 chat, F8 on top, F6 back to live, F2 menu"
            case "Settings": return "Rest the mouse on a setting to read what it does"
            case "Account": return "Optional. With a login streamlink plays without ads if you have Turbo or a sub to the channel, and opens "
                . "sub-only streams. Without one everything still works, with ads"
            default: return "What Puddock needs. A green dot: that part is ready"
        }
    }

    OnEnter() {
        if (this.page = "Watch")
            this.Watch()
        else if (this.page = "Settings")
            this.Save()
        else if (this.page = "Account")
            this.SaveTokenUI()
    }

    ; ---------- layout ----------
    Layout(mm, w, h) {
        if (mm = -1)                                            ; minimized
            return
        s := this.S, W := w / s, H := h / s
        cx := Launcher.SIDE + Launcher.PAD, cw := W - Launcher.SIDE - 2 * Launcher.PAD
        DllCall("SendMessage", "Ptr", this.g.Hwnd, "UInt", 0xB, "Ptr", 0, "Ptr", 0)   ; WM_SETREDRAW off

        MoveWin(this.sb.Hwnd, 0, 0, Round(Launcher.SIDE * s), h)
        this.Put(this.name, 64, 22, 104, 20)
        this.Put(this.ver, 64, 42, 104, 16)
        for n, o in this.nav
            this.Put(o.c, 8, o.y, 160, 32)
        if this.nav.Has(this.page)
            this.Put(this.bar, 0, this.nav[this.page].y + 6, 3, 20)
        this.Put(this.acctDot, 20, H - 50, 8, 8)
        this.Put(this.acctHdr, 36, H - 56, 132, 20)
        this.Put(this.state, 36, H - 36, 132, 18)

        this.LayoutWatch(cx, cw, H)
        this.LayoutSettings(cx, cw)
        this.LayoutAccount(cx, cw)
        this.LayoutSetup(cx, cw)
        this.Put(this.rule, cx, H - 68, cw, 1)
        this.Put(this.desc, cx, H - 58, cw, 46)

        DllCall("SendMessage", "Ptr", this.g.Hwnd, "UInt", 0xB, "Ptr", 1, "Ptr", 0)   ; WM_SETREDRAW on
        DllCall("RedrawWindow", "Ptr", this.g.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x585)
        if (this.page = "Watch")
            this.RefreshList()                                  ; a wider list has more room between name and time
    }

    LayoutWatch(cx, cw, H) {
        this.Put(this.chan, cx, 28, cw - 120, 36)
        this.Put(this.watchBtn, cx + cw - 112, 28, 112, 36)
        this.Put(this.listLbl, cx, 88, 160, 20)
        this.Put(this.favBtn, cx + cw - 176, 84, 88, 28)
        this.Put(this.remBtn, cx + cw - 80, 84, 80, 28)
        this.Put(this.lv, cx, 120, cw, H - 68 - 16 - 120)
    }

    LayoutSettings(cx, cw) {
        fw := Min(cw, 640)
        this.Put(this.defBtn, cx + cw - 200, 16, 96, 32)
        this.Put(this.saveBtn, cx + cw - 96, 16, 96, 32)
        y := 24
        for i, rows in this.groups {
            this.Put(this.grp[i], cx, y, 160, 20)
            y += 28
            for r in rows {
                r.Put(this, cx, y, fw)
                y += 36
            }
            y += 12
        }
    }

    LayoutAccount(cx, cw) {
        fw := Min(cw, 640)
        this.Put(this.acctBig, cx, 34, 8, 8)
        this.Put(this.acctTxt, cx + 16, 28, fw - 128, 20)
        this.Put(this.acctSub, cx + 16, 50, fw - 128, 18)
        this.Put(this.outBtn, cx + fw - 96, 24, 96, 32)
        this.Put(this.conLbl, cx, 104, fw, 20)
        this.Put(this.conTxt, cx, 132, cw, 20)
        this.Put(this.conBtn, cx, 164, 200, 36)
        this.Put(this.tokLbl, cx, 236, fw, 20)
        this.Put(this.tokenEd, cx, 264, fw - 208, 32)
        this.Put(this.tokSave, cx + fw - 200, 264, 96, 32)
        this.Put(this.tokTest, cx + fw - 96, 264, 96, 32)
    }

    LayoutSetup(cx, cw) {
        fw := Min(cw, 680), y := 28
        for key in this.sorder {
            r := this.srow[key]
            this.Put(r.name, cx, y, 180, 20)
            this.Put(r.dot, cx + 196, y + 6, 8, 8)
            this.Put(r.status, cx + 212, y, fw - 212 - 216, 20)
            this.Put(r.hint, cx, y + 24, fw - 216, 18)
            if r.b2
                this.Put(r.b1, cx + fw - 200, y + 4, 96, 32), this.Put(r.b2, cx + fw - 96, y + 4, 96, 32)
            else
                this.Put(r.b1, cx + fw - 200, y + 4, 200, 32)
            y += 68
        }
        this.Put(this.shortLbl, cx, y + 8, 160, 20)
        this.Put(this.deskBtn, cx, y + 36, 128, 32)
        this.Put(this.startBtn, cx + 136, y + 36, 128, 32)
    }

    ; Place a control (x, y, w, h in the launcher's units), or anything that knows how to place
    ; itself (Field, Toggle, Segment). Everything has square corners, on purpose and by necessity:
    ; a window region can't round a Text control (its class draws with the parent's DC, which
    ; ignores the control's own region), so buttons could never match rounded fields.
    Put(c, x, y, w, h) {
        if !(c is Gui.Control)
            return c.Place(this, x, y, w, h)
        s := this.S
        c.Move(Round(x * s), Round(y * s), Round(w * s), Max(1, Round(h * s)))
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
        this.Flash("Opening " ch "…", T.muted)
        if this.cfg["CloseLauncher"]
            this.Quit()
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
        favs := GetList("Favorites"), rec := GetList("Recent"), n := this.ListCols()
        raw := Join(favs) "#" Join(rec) "#"
        if (!force && raw n = this.lastRaw)
            return
        this.FillList(favs, rec, n)
        if (n2 := this.ListCols()) != n                         ; a scrollbar came or went: the list is narrower / wider
            this.FillList(favs, rec, n := n2)
        this.lastRaw := raw n
    }

    FillList(favs, rec, n) {
        lv := this.lv, sel := this.Selected(), this.rows := [], seen := Map()
        this.filling := true
        lv.Opt("-Redraw")
        lv.Delete()
        when := Map()
        for e in rec {
            p := StrSplit(e, "/")
            when[p[1]] := p.Length > 1 ? p[2] : ""
        }
        for ch in favs {
            lv.Add(, this.ListLine("  * " ch, when.Has(ch) ? Ago(when[ch]) : "", n))
            this.rows.Push(ch), seen[ch] := 1
        }
        for e in rec {
            ch := StrSplit(e, "/")[1]
            if seen.Has(ch)
                continue
            lv.Add(, this.ListLine("    " ch, Ago(when[ch]), n))
            this.rows.Push(ch), seen[ch] := 1
        }
        if !this.rows.Length {
            lv.Add(, "    No channels yet. Type one above and press Enter")
            this.rows.Push("")
        }
        lv.ModifyCol(1, "AutoHdr")
        if (sel != "" && (row := IndexOf(this.rows, sel)))
            lv.Modify(row, "Select Focus")
        lv.Opt("+Redraw")
        this.filling := false
    }

    ; name on the left, time on the right, `n` characters in all (the font has one width)
    ListLine(left, right, n) {
        return left StrRepeat(" ", Max(2, n - StrLen(left) - StrLen(right))) right
    }

    ; how many characters fit into one row of the list
    ListCols() {
        rc := Buffer(16, 0), sz := Buffer(8, 0), lv := this.lv
        DllCall("GetClientRect", "Ptr", lv.Hwnd, "Ptr", rc)
        hdc := DllCall("GetDC", "Ptr", lv.Hwnd, "Ptr")
        old := DllCall("SelectObject", "Ptr", hdc, "Ptr", SendMessage(0x31, 0, 0, lv), "Ptr")   ; WM_GETFONT
        DllCall("GetTextExtentPoint32", "Ptr", hdc, "Str", "0000000000", "Int", 10, "Ptr", sz)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
        DllCall("ReleaseDC", "Ptr", lv.Hwnd, "Ptr", hdc)
        cw := NumGet(sz, 0, "Int") / 10
        return cw > 0 ? Max(30, Floor((NumGet(rc, 8, "Int") - Round(24 * this.S)) / cw)) : 60
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
        SaveConfig(c)
        this.cfg := LoadConfig()
        FlashText(this.saveBtn, "Saved")
    }

    Browse(key, exe) {
        this.g.Opt("+OwnDialogs")
        p := FileSelect(1, , "Select " exe, "Programs (*.exe)")
        if (p != "")
            this.f[key].Value := p
    }

    ; ---------- Setup page, readiness ----------
    UpdateStatus(*) {
        tools := FindTools(LoadConfig())
        for key in ["streamlink", "mpv"] {
            path := tools.%key%
            this.SetupState(key, path != "", path != "" ? "Installed" : "Not found"
                , path != "" ? path : "Install with winget, or Browse… to " key ".exe")
            this.srow[key].b1.Text := path != "" ? "Reinstall" : "Install"
        }
        ext := ExtensionSeenRecently()
        this.SetupState("ext", ext, ext ? "Connected" : "Not connected yet"
            , ext ? "Seen in your browser in the last 30 days" : "Load it into your browser: Open folder")
        host := NativeHostRegistered()
        this.SetupState("host", host, host ? "Registered" : "Not registered", "Chrome, Chromium, Edge, Brave, Vivaldi, Firefox")
        this.srow["host"].b1.Text := host ? "Re-register" : "Register"

        ; sidebar: the first thing still missing, or "ready"
        missing := tools.streamlink = "" || tools.mpv = "" ? "tools missing"
                 : !host ? "not registered"
                 : !ext ? "no extension yet" : ""
        this.setupOk := missing = ""
        this.state.Text := missing = "" ? "ready" : missing
        this.state.SetFont("c" (missing = "" ? T.dim : T.warn))
    }

    ; the accent goes to the one button that fixes what is missing, and to nothing once it's fine
    SetupState(key, ok, text, hint) {
        r := this.srow[key]
        r.status.Text := text
        r.status.SetFont("c" (ok ? T.muted : T.warn))
        r.hint.Text := hint
        this.SetDot(r.dot, ok ? T.ok : T.warn)
        this.Paint(r.b1, ok ? T.input : T.accent, ok ? T.hover : T.accentHi, ok ? T.text : "FFFFFF")
    }

    OpenExtFolder() {
        if DirExist(EXT_DIR)
            Run(ArgQuote(A_WinDir "\explorer.exe") " " ArgQuote(EXT_DIR))
        else
            this.Flash("Extension folder not found: " EXT_DIR, T.warn)
    }

    ; ---------- building blocks ----------
    Add(type, opt := "", text := "") {
        c := this.g.Add(type, opt, text)
        this.Track(c)
        return c
    }

    Track(c) {
        if (this.cur != "")
            this.pages[this.cur].Push(c)
    }

    ; one line of text; with `help`, resting the mouse on it shows that description
    Label(text, help := "", color := "") {
        c := this.Add("Text", "x0 y0 w10 h10 +0x200 +0x100 c" (color != "" ? color : T.muted), text)   ; SS_NOTIFY: gets the mouse
        this.Help(c, help)
        return c
    }

    ; small status light
    Dot(owner := 0) {
        c := (owner || this.g).AddText("x0 y0 w8 h8 Background" T.dim)
        if !owner
            this.Track(c)
        return c
    }

    SetDot(c, color) {
        c.Opt("+Background" color)
        c.Redraw()
    }

    ; Flat button made from a Text control (real buttons can't be coloured).
    ;   accent: the page's one main action     ghost: an ordinary button
    ;   plain:  text that turns into a button under the mouse     nav: a sidebar entry
    Button(text, cb, kind := "ghost", owner := 0) {
        c := (owner || this.g).AddText("x0 y0 w10 h10 +0x200" (kind = "nav" ? "" : " Center"), text)
        if !owner
            this.Track(c)
        this.btns[c.Hwnd] := {bg: "", hi: ""}
        switch kind {
            case "accent": this.Paint(c, T.accent, T.accentHi, "FFFFFF")
            case "plain":  this.Paint(c, T.bg, T.input, T.muted)
            case "nav":    this.Paint(c, T.panel, T.hover, T.muted)
            default:       this.Paint(c, T.input, T.hover, T.text)
        }
        c.OnEvent("Click", cb)
        return c
    }

    Paint(c, bg, hi, fg := "") {
        b := this.btns[c.Hwnd], b.bg := bg, b.hi := hi
        c.Opt("+Background" (this.hot = c.Hwnd ? hi : bg))
        if (fg != "")
            c.SetFont("c" fg)
        c.Redraw()
    }

    ; ---------- the description line ----------
    ; `thing`: a control, or a Field / Toggle / Segment (all of its windows)
    Help(thing, text) {
        if (text = "")
            return
        for h in (thing is Gui.Control) ? [thing.Hwnd] : thing.Hwnds
            this.tips[h] := text
    }

    SetDesc(text) {
        this.descText := text
        if (A_TickCount >= this.flashUntil)
            this.ShowDesc(text, T.dim)
    }

    ShowDesc(text, color) {
        this.desc.Text := text
        this.desc.SetFont("c" color)
    }

    ; a result ("Saved", "Opening lirik…") takes the line for a moment
    Flash(text, color) {
        this.ShowDesc(text, color)
        this.flashUntil := A_TickCount + 2500
        SetTimer(this.restoreFn, -2600)
    }

    RestoreDesc() {
        if (A_TickCount >= this.flashUntil)
            this.ShowDesc(this.descText, T.dim)
    }

    ; ---------- hover / cursor ----------
    OnMouseMove(wParam, lParam, msg, hwnd) {
        if (hwnd != this.helpAt && this.tips.Has(hwnd)) {
            this.helpAt := hwnd
            this.SetDesc(this.tips[hwnd])
        }
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
        if !this.btns.Has(wParam) && !(wParam = this.acctHdr.Hwnd || wParam = this.state.Hwnd && !this.setupOk)
            return
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr"))    ; IDC_HAND
        return 1
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
