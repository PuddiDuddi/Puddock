#Requires AutoHotkey v2.0
; Puddock — the native messaging host and its registration (part of puddock.ahk, included from there)

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
    global HOST_OUT
    hIn := DllCall("GetStdHandle", "Int", -10, "Ptr"), HOST_OUT := hOut := DllCall("GetStdHandle", "Int", -11, "Ptr")
    Loop {
        if HOST_PORT && !WaitForInput(hIn)                      ; a port: stay responsive between messages
            break
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

; Port mode. A plain read would block this (single) thread until the extension says something,
; and the player's requests (PortCommand, a window message) would never be heard. So look whether
; there is something to read, and let messages through in between.
; -> true: go and read; false: the browser closed the port, or no player has been around for a minute.
WaitForInput(h) {
    idle := 0
    Loop {
        avail := 0
        if !DllCall("PeekNamedPipe", "Ptr", h, "Ptr", 0, "UInt", 0, "Ptr", 0, "UInt*", &avail, "Ptr", 0)
            return !HasVal([109, 232, 233], A_LastError)        ; BROKEN_PIPE / NO_DATA / PIPE_NOT_CONNECTED: closed.
                                                                ; anything else: can't peek here, read as before
        if avail
            return true
        Sleep(15)
        if Mod(A_Index, 128) = 0 {                              ; every ~2 s
            idle := WinExist("^\w+ · " APP "$ ahk_class AutoHotkeyGUI") ? 0 : idle + 1
            if (idle >= 30)
                return false
        }
    }
}

; The player asks for something in the chat page (Player.PortSend): one word from a fixed list,
; passed on to the extension. Any program of this user could send this message too — and would
; get the chat's settings opened, zoomed or reloaded, nothing else.
PortCommand(wParam, lParam, *) {
    static actions := ["settings", "zoomIn", "zoomOut", "zoomReset", "reload"]
    n := NumGet(lParam, A_PtrSize, "UInt"), p := NumGet(lParam, A_PtrSize * 2, "Ptr")
    if (!p || n < 2 || n > 64 || Mod(n, 2))
        return 0
    action := StrGet(p, n // 2, "UTF-16")
    for a in actions
        if (a == action)
            return WriteMessage(HOST_OUT, Map("type", "chat", "action", a)) ? 1 : 0
    return 0
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
    written := 0                                                ; one write per message: never interleaved
    return DllCall("WriteFile", "Ptr", h, "Ptr", buf, "UInt", 4 + len, "UInt*", &written, "Ptr", 0)
}

HostHandle(msg) {
    global HOST_PORT
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
        case "attach":                                          ; over a port that stays open for this chat:
            nonce := msg.Get("nonce", "")                       ; from now on the player can reach the extension
                                                                ; through this process (PortCommand)
            if !CheckNonce("Chat", nonce, false)
                return Map("ok", 0, "error", "bad request")
            if !HOST_PORT {
                HOST_PORT := true
                OnMessage(0x4A, PortCommand)                    ; WM_COPYDATA
            }
            DllCall("SetWindowText", "Ptr", A_ScriptHwnd, "Str", PORT_TITLE nonce)
            return Map("ok", 1)
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

AllowedChromiumIds() => CHROMIUM_IDS

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

