#Requires AutoHotkey v2.0
; Puddock — data folder, single instance, channel parsing (part of puddock.ahk, included from there)

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
            try {                                            ; it may close at any moment: then just look again
                if (WinGetTitle(hwnd) = ch " · " APP) {
                    BringToFront(hwnd)
                    return false
                }
                if (hwnd != closed)
                    WinClose(hwnd), closed := hwnd
            }
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
    try {                                                    ; another process's window: it may be gone by now
        if (WinGetMinMax(hwnd) = -1)
            WinRestore(hwnd)
        WinActivate(hwnd)
    }
}

; "xqc", "https://www.twitch.tv/xqc" -> "xqc"
ParseChannel(s) {
    s := Trim(String(s), " `t`r`n")
    if RegExMatch(s, "i)twitch\.tv/(?:popout/|moderator/)?([^/?#]+)", &m)
        s := m[1]
    s := StrLower(Trim(s, " /"))
    return RegExMatch(s, "^[a-z0-9_]{1,25}\z") ? s : ""       ; \z: "$" would let a trailing newline through
}

SelfCmd(args*) {
    cmd := A_IsCompiled ? ArgQuote(A_ScriptFullPath) : ArgQuote(A_AhkPath) " " ArgQuote(A_ScriptFullPath)
    for a in args
        cmd .= " " ArgQuote(a)
    return cmd
}


