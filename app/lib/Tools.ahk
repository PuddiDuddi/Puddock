#Requires AutoHotkey v2.0
; Puddock — finding streamlink, mpv and a browser (part of puddock.ahk, included from there)

; ---------- dependencies ----------
; streamlink / mpv as full paths: the configured path, then where installers put them (winget's
; links, Program Files, the user's own folders), and only then PATH — re-read from the registry so
; a fresh install is found without logging off. Shared spots other accounts can write to
; (%ProgramData%, %PUBLIC%) are skipped even when they are on PATH (PathDirs) — a tool installed
; there needs its path set by hand; anything else on PATH is shown in Setup with its full path.
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
            if RegExMatch(d := RTrim(Trim(d, ' "'), "\"), "^(?:[A-Za-z]:(?:\\|\z)|\\\\)") && !HasVal(dirs, d)   ; absolute only ("C:" = the root, trimmed)
               && !IsUnder(d, EnvGet("ProgramData")) && !IsUnder(d, EnvGet("PUBLIC"))   ; shared, writable by others
                dirs.Push(d)
    return dirs
}

; is `path` the folder `root` or something inside it? (whole path components, case-insensitive)
IsUnder(path, root) {
    root := RTrim(root, "\")
    return root != "" && InStr(RTrim(path, "\") "\", root "\") = 1
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

