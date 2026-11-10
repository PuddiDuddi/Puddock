#Requires AutoHotkey v2.0
; Puddock — settings, channel lists, the streamlink command line (part of puddock.ahk, included from there)

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

