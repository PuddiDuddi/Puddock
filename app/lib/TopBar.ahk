#Requires AutoHotkey v2.0
; Puddock — the slide-down toolbar of the player (part of puddock.ahk, included from there)

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
        this.hdShown := false, this.hdX := 0, this.hdY := 0, this.hdFg := 0

        OnMessage(0x200, ObjBindMethod(this, "OnMouseMove"))
        this.tickFn := ObjBindMethod(this, "Check")
        this.awake := false
        this.Wake()
    }

    ; The mouse is over windows of other processes (mpv), so hovering can only be noticed by
    ; looking — but only while the player is in front: Check() stops the timer when it isn't, and
    ; the player's foreground event (Player.OnForeground) starts it again.
    Wake() {
        if this.awake
            return
        this.awake := true
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
            SetTimer(this.tickFn, 0), this.awake := false       ; until Wake()
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

    ; Called every 60 ms: only touch the window when something changed — it was hidden, the video
    ; moved, or another window came to the front (the one moment the z-order can change, e.g. mpv
    ; in its own always-on-top window covering the handle).
    ShowHandle(on, x := 0, y := 0) {
        if on {
            fg := DllCall("GetForegroundWindow", "Ptr")
            if this.hdShown && x = this.hdX && y = this.hdY && fg = this.hdFg
                return
            DllCall("SetWindowPos", "Ptr", this.hd.Hwnd, "Ptr", -1, "Int", x, "Int", y, "Int", 0, "Int", 0
                  , "UInt", 0x51)                             ; HWND_TOPMOST, NOSIZE|NOACTIVATE|SHOWWINDOW
            this.hdX := x, this.hdY := y, this.hdFg := fg
        } else if this.hdShown
            DllCall("ShowWindow", "Ptr", this.hd.Hwnd, "Int", 0)
        this.hdShown := on                                    ; hidden: the next show always places it again
    }

    Place() {
        v := WinRect(this.pl.vg.Hwnd)
        DllCall("SetWindowPos", "Ptr", this.g.Hwnd, "Ptr", -1, "Int", v[1] + (v[3] - v[1] - this.w) // 2, "Int", v[2]
              , "Int", 0, "Int", 0, "UInt", 0x51)             ; HWND_TOPMOST, NOSIZE|NOACTIVATE|SHOWWINDOW
    }

    Show() {
        this.Wake()
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

