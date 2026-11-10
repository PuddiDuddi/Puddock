#Requires AutoHotkey v2.0
; Puddock — chat URL, chat window title, nonces (part of puddock.ahk, included from there)

; ---------- chat helpers ----------
ChatUrl(ch, dark, nonce := "") {
    q := []
    if dark
        q.Push("darkpopout")
    if (nonce != "")
        q.Push("puddock=" nonce)
    return "https://www.twitch.tv/popout/" ch "/chat" (q.Length ? "?" Join(q, "&") : "")
}

; Is `title` the title of the --app chat window we started for channel `ch`? That window gets
; embedded and later closed, so "contains the channel name" or "contains chat" is far too wide
; (a channel called "a", a ChatGPT window…). Accepted, all case-insensitive:
;   - the address Chromium shows until the page has a title: "…twitch.tv/popout/<ch>/chat…"
;   - the channel name as a whole word together with "Twitch" or "chat" as whole words
;   - exactly "Twitch": what the popout calls itself. An --app window has no " - <browser>"
;     suffix, so an ordinary browser window showing twitch.tv never has this title.
IsChatTitle(title, ch) {
    if !RegExMatch(ch, "^[a-z0-9_]{1,25}\z")                   ; goes into a regex below
        return false
    if RegExMatch(title, "i)(?<![\w-])popout/" ch "/chat(?![\w-])")
        return true
    rest := RegExReplace(title, "i)(?<!\w)" ch "(?!\w)", " ", &found)   ; a channel named "chat" isn't both
    if found && RegExMatch(rest, "i)(?<!\w)(?:twitch|chat)(?!\w)")
        return true
    return RegExMatch(title, "i)^\s*Twitch\s*$") != 0
}

; One-time values the app hands to the browser through a URL (chat window / connect request).
; The extension asks us (checkNonce) before acting on one, so a web page can't fake them.
; Stored in settings.ini as "<nonce>|<timestamp>" entries joined with "," (one entry is what
; earlier builds wrote, so that still reads). "Chat" keeps the last few: two watch requests in
; quick succession must not overwrite each other, and the chat asks again on every (re)load, so
; its nonce stays valid for its 10 minutes. "Connect" is a single one, gone once checked.
RememberNonce(kind, nonce) {
    chat := kind = "Chat"
    IniWrite(NonceAdd(chat ? IniRead(INI_FILE, "State", kind "Nonce", "") : "", nonce, A_Now, chat ? 10 : 2, chat ? 4 : 1)
           , INI_FILE, "State", kind "Nonce")
}

CheckNonce(kind, nonce, consume) {
    fresh := NonceFresh(IniRead(INI_FILE, "State", kind "Nonce", ""), nonce, A_Now, kind = "Chat" ? 10 : 2)
    if (fresh && consume)
        IniDelete(INI_FILE, "State", kind "Nonce")
    return fresh
}

; `list` plus `nonce`: newest first, without expired or malformed entries, at most `keep` of them
NonceAdd(list, nonce, now, minutes, keep) {
    out := [nonce "|" now]
    for e in StrSplit(list, ",") {
        p := StrSplit(e, "|")
        if (out.Length < keep && p.Length = 2 && p[1] !== nonce && NonceFresh(e, p[1], now, minutes))
            out.Push(e)
    }
    return Join(out, ",")
}

; is `nonce` in `list` and younger than `minutes`?
NonceFresh(list, nonce, now, minutes) {
    if !RegExMatch(nonce, "^[a-f0-9]{16,64}\z")
        return false
    for e in StrSplit(list, ",") {
        p := StrSplit(e, "|")
        try {                                                   ; a broken timestamp throws: not fresh
            if (p.Length = 2 && p[1] == nonce && DateDiff(now, p[2], "Minutes") < minutes)
                return true
        }
    }
    return false
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

