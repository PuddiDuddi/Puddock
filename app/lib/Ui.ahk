#Requires AutoHotkey v2.0
; Puddock — window, drawing and small general helpers (part of puddock.ahk, included from there)

MakeShortcut(dir) {
    lnk := dir "\" APP ".lnk"
    if A_IsCompiled
        FileCreateShortcut(A_ScriptFullPath, lnk, A_ScriptDir, , APP)
    else
        FileCreateShortcut(A_AhkPath, lnk, A_ScriptDir, '"' A_ScriptFullPath '"', APP, FileExist(ICON) ? ICON : "")
}

; A wrapped Text control has a fixed height in the layout. Measure its text with its own font
; (real pixels, so DPI and font fallback are included) and step the font down until it all fits,
; instead of silently cutting off the last line.
FitText(ctl, size := 9, minSize := 7) {
    ControlGetPos(, , &w, &h, ctl)
    loop {
        ctl.SetFont("s" size)
        if (size <= minSize || TextHeight(ctl, w) <= h)
            return
        size--
    }
}

TextHeight(ctl, w) {
    hdc := DllCall("GetDC", "Ptr", ctl.Hwnd, "Ptr")
    old := DllCall("SelectObject", "Ptr", hdc, "Ptr", SendMessage(0x31, 0, 0, ctl), "Ptr")   ; WM_GETFONT
    rc := Buffer(16, 0), NumPut("Int", w, rc, 8)
    DllCall("DrawText", "Ptr", hdc, "Str", ctl.Text, "Int", -1, "Ptr", rc, "UInt", 0x410)    ; CALCRECT|WORDBREAK
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
    DllCall("ReleaseDC", "Ptr", ctl.Hwnd, "Ptr", hdc)
    return NumGet(rc, 12, "Int")
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
