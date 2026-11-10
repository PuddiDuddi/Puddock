#Requires AutoHotkey v2.0
; Puddock — the Twitch token: Credential Manager, validation, masking (part of puddock.ahk, included from there)

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
    s := RegExReplace(Trim(s, " `t`r`n"), "i)^(oauth\s+|auth-token=)")
    return RegExMatch(s, "^[A-Za-z0-9]{20,64}\z") ? s : ""     ; \z: "$" would let a trailing newline through
}

; -> {login, clientId, expires}; 0 if Twitch rejects the token; throws if Twitch can't be reached
; (or answers with something that isn't the expected JSON)
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
    return TokenInfo(req.ResponseText)
}

; Twitch's answer to a valid token -> {login, clientId, expires}; throws if it isn't that
TokenInfo(body) {
    j := Json.Parse(body)
    if !(j is Map)
        throw ValueError("unexpected answer from Twitch")
    login := j.Get("login", ""), client := j.Get("client_id", ""), expires := j.Get("expires_in", 0)
    if !(login is String && login != "" && client is String && client != "" && expires is Integer)
        throw ValueError("unexpected answer from Twitch")
    return { login: login, clientId: client, expires: expires }
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

