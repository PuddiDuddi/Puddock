#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
; ---------------------------------------------------------------------------
;  Tests for Puddock's pure functions.
;
;    AutoHotkey64.exe /ErrorStdOut tests\run.ahk | more      (piped, so the console waits for it)
;
;  Prints one line per failure to stdout and exits with 1 if anything failed (0 otherwise).
;
;  How it gets at the functions: app\puddock.ahk is included as it is, at the BOTTOM of this file.
;  Functions and classes exist as soon as the script is loaded, wherever they are written, while
;  the app's own start-up code only runs when execution reaches it — and it never does, because
;  the line below runs the tests and exits first. So the app needs no "test mode" switch.
;  The price: the app's globals (APP, INI_FILE, DEFAULTS…) are still unset here, so only functions
;  that don't use them can be tested — which is also what keeps these tests away from the real
;  settings.ini, the registry and Credential Manager.
; ---------------------------------------------------------------------------
ExitApp(RunTests())          ; nothing below this line is ever executed

RunTests() {
    try {
        TestParseChannel()
        TestArgQuote()
        TestSharedValue()
        TestCleanToken()
        TestJson()
        TestNonces()
        TestTokenInfo()
        TestChatTitle()
        TestIsUnder()
    } catch as e {
        TestOut("ERROR  " Type(e) ": " e.Message (e.Extra != "" ? " (" e.Extra ")" : "") "`n" e.Stack)
        return 2
    }
    r := TestCount()
    TestOut((r.failed ? "FAILED" : "ok") ": " r.total - r.failed " of " r.total " checks passed")
    return r.failed ? 1 : 0
}

; ---------- harness ----------
TestOut(text) {
    try FileAppend(text "`n", "*", "UTF-8")          ; stdout; there is none when started by double-click
}

TestCount(failed := -1) {
    static total := 0, fails := 0
    if (failed >= 0)
        total++, fails += failed
    return {total: total, failed: fails}
}

TestShow(v) => v is Object ? Type(v) : (v is String ? '"' v '"' : String(v))

; same type and same value (strings compared case-sensitively)
TestEq(name, got, want) {
    ok := Type(got) = Type(want) && !(got is Object) && got == want
    TestCount(!ok)
    if !ok
        TestOut("FAIL  " name ": got " TestShow(got) ", expected " TestShow(want))
}

TestThrows(name, fn) {
    try fn()
    catch {
        TestCount(0)
        return
    }
    TestCount(1)
    TestOut("FAIL  " name ": expected an error")
}

; ---------- the tests ----------
TestParseChannel() {
    for input, want in Map(
        "xqc", "xqc",
        "XQC", "xqc",
        "  xqc/ ", "xqc",
        "https://www.twitch.tv/xQc", "xqc",
        "https://www.twitch.tv/xqc?tt_content=x#frag", "xqc",
        "twitch.tv/popout/some_channel/chat?darkpopout", "some_channel",
        "https://www.twitch.tv/moderator/xqc", "xqc",
        "a1234567890123456789012345", "",                     ; 26 characters
        "a123456789012345678901234", "a123456789012345678901234",
        "", "",
        "two words", "",
        "xqc --player evil", "",
        'xqc"', "",
        "xqc;calc", "",
        "xqc`n", "xqc",                                       ; pasted with a line break: trimmed
        "xqc`nevil", "",
        "ünicode", "")
        TestEq("ParseChannel(" input ")", ParseChannel(input), want)
    TestEq("ParseChannel(12345)", ParseChannel(12345), "12345")
}

TestArgQuote() {
    for input, want in Map(
        "abc", "abc",
        "C:\tools\mpv.exe", "C:\tools\mpv.exe",
        "", '""',
        "a b", '"a b"',
        'a"b', '"a\"b"',
        "C:\Program Files\x\", '"C:\Program Files\x\\"',
        'a\"b', '"a\\\"b"',
        "tab`there", '"tab`there"')
        TestEq("ArgQuote(" input ")", ArgQuote(input), want)
    TestEq("ArgQuote(5)", ArgQuote(5), "5")
    ; and the other way round: Windows must read every argument back exactly as it went in
    args := ["plain", "", "a b", 'say "hi"', "C:\dir with space\", 'back\\slash\"quote', "\\.\pipe\puddock-x"
           , '\', '"', "--player-args=--wid=123 --title=a b", "trailing\\", ' lead', "a`tb"]
    line := "prog"
    for a in args
        line .= " " ArgQuote(a)
    n := 0
    argv := DllCall("shell32\CommandLineToArgvW", "Str", line, "Int*", &n, "Ptr")
    TestEq("CommandLineToArgvW: count", n, args.Length + 1)
    for a in args
        if (A_Index < n)
            TestEq("CommandLineToArgvW: argument " A_Index, StrGet(NumGet(argv, A_Index * A_PtrSize, "Ptr")), a)
    DllCall("LocalFree", "Ptr", argv)
}

TestSharedValue() {
    ; [key, value, accepted, result]
    for c in [["LowLatency", 1, true, 1], ["LowLatency", 0, true, 0], ["LowLatency", "1", true, 1]
            , ["LowLatency", 2, false], ["LowLatency", "yes", false], ["LowLatency", "", false]
            , ["Quality", "720p60", true, "720p60"], ["Quality", "best", true, "best"]
            , ["Quality", "4k", false], ["Quality", "BEST", false], ["Quality", "best --player x", false]
            , ["Rewind", 15, true, 15], ["Rewind", "15", true, 15], ["Rewind", 7, false]
            , ["VideoMode", "Window", true, "Window"], ["VideoMode", "window", false]
            , ["ChatSide", "Left", true, "Left"], ["ChatSide", "Top", false]
            , ["ChatWidth", 200, true, 200], ["ChatWidth", "1200", true, 1200], ["ChatWidth", 199, false]
            , ["ChatWidth", 1201, false], ["ChatWidth", "wide", false], ["ChatWidth", 300.5, false]
            , ["MpvPath", "C:\x.exe", false], ["StreamlinkArgs", "--x", false], ["", 1, false]] {
        out := "(unset)"
        ok := SharedValue(c[1], c[2], &out)
        TestEq("SharedValue(" c[1] ", " TestShow(c[2]) ")", ok ? 1 : 0, c[3] ? 1 : 0)
        if (ok && c[3])
            TestEq("SharedValue(" c[1] ", " TestShow(c[2]) ") result", out, c[4])
    }
}

TestCleanToken() {
    tok := "abcdefghij0123456789ABCDEFGHIJ"
    TestEq("CleanToken plain", CleanToken(tok), tok)
    TestEq("CleanToken trims", CleanToken("  " tok "`n"), tok)
    TestEq("CleanToken OAuth", CleanToken("OAuth " tok), tok)
    TestEq("CleanToken oauth", CleanToken("oauth   " tok), tok)
    TestEq("CleanToken cookie", CleanToken("auth-token=" tok), tok)
    TestEq("CleanToken short", CleanToken("abc123"), "")
    TestEq("CleanToken long", CleanToken(tok tok tok), "")
    TestEq("CleanToken symbols", CleanToken(tok "-x"), "")
    TestEq("CleanToken inner space", CleanToken("abcdefghij 0123456789ABCDEFGHIJ"), "")
    TestEq("CleanToken empty", CleanToken(""), "")
    TestEq("CleanToken inner line break", CleanToken(tok "`n" tok), "")
    TestEq("NonceFresh trailing line break", NonceFresh("aaaaaaaaaaaaaaaa|20260101120000", "aaaaaaaaaaaaaaaa`n", "20260101120000", 10), 0)
}

TestJson() {
    ; text -> value -> the same text (Map keys come back sorted, so they are sorted here)
    for text in ['{"a":1,"b":"two","c":[1,2,3],"d":{"e":-4}}', "[]", "{}", '""', "0", "-12", '[1.5,"x",[[]]]'
               , '"quote \" backslash \\ newline \n tab \t"', '{"channel":"xqc","cmd":"watch","nonce":"00ff"}']
        TestEq("Json round trip " text, Json.Stringify(Json.Parse(text)), text)

    v := Json.Parse(' { "t" : true , "f":false, "n":null, "i": 42, "x": 4.5, "e": 1e2, "s":"\u00e9\/\b", "a":[ ] } ')
    TestEq("Json true", v["t"], 1)
    TestEq("Json false", v["f"], 0)
    TestEq("Json null", v["n"], "")
    TestEq("Json integer", v["i"], 42)
    TestEq("Json float", v["x"], 4.5)
    TestEq("Json exponent", v["e"], 100.0)
    TestEq("Json escapes", v["s"], Chr(0xE9) "/" Chr(8))
    TestEq("Json empty array", v["a"].Length, 0)
    TestEq("Json number stays a number", Json.Parse('{"v":1}')["v"] is Number, 1)
    TestEq("Json string stays a string", Json.Parse('{"v":"1"}')["v"] is Number, 0)

    TestEq("Json.Stringify object", Json.Stringify({ok: 1}), '{"ok":1}')
    TestEq("Json.Stringify control character", Json.Stringify(Chr(1) "`r"), '"\u0001\r"')
    TestEq("Json.Stringify nested", Json.Stringify(Map("a", [1, "x", Map()])), '{"a":[1,"x",{}]}')

    deep := ""
    Loop 20
        deep .= "["
    for bad in ["", "{", "[1,]", '{"a":}', '{"a" 1}', "{a:1}", '"abc', "tru", "1 2", "[1 2]", '"\x"', '"\u12"'
              , "{} x", "'a'", "-", deep]
        TestThrows("Json.Parse(" bad ") must fail", () => Json.Parse(bad))
}

TestNonces() {
    a := "aaaaaaaaaaaaaaaa", b := "bbbbbbbbbbbbbbbb", c := "cccccccccccccccc", d := "dddddddddddddddd"
    e := "eeeeeeeeeeeeeeee", t := "20260101120000"
    TestEq("NonceAdd first", NonceAdd("", a, t, 10, 4), a "|" t)
    two := NonceAdd(a "|" t, b, "20260101120100", 10, 4)
    TestEq("NonceAdd second keeps the first", two, b "|20260101120100," a "|" t)
    TestEq("NonceFresh finds the older one", NonceFresh(two, a, "20260101120500", 10), 1)
    TestEq("NonceFresh finds the newer one", NonceFresh(two, b, "20260101120500", 10), 1)
    TestEq("NonceFresh more than once", NonceFresh(two, a, "20260101120900", 10), 1)
    TestEq("NonceFresh expired", NonceFresh(two, a, "20260101121000", 10), 0)
    TestEq("NonceFresh other one not yet", NonceFresh(two, b, "20260101121000", 10), 1)
    TestEq("NonceFresh unknown", NonceFresh(two, c, "20260101120500", 10), 0)
    TestEq("NonceFresh old single-entry format", NonceFresh(a "|" t, a, "20260101120100", 2), 1)
    TestEq("NonceFresh empty list", NonceFresh("", a, t, 10), 0)
    TestEq("NonceFresh empty nonce", NonceFresh(two, "", t, 10), 0)
    TestEq("NonceFresh malformed nonce", NonceFresh("xyz|" t, "xyz", t, 10), 0)
    TestEq("NonceFresh nonce with separators", NonceFresh(two, a "|" t, t, 10), 0)
    TestEq("NonceFresh prefix of a nonce", NonceFresh(a a "|" t, a, t, 10), 0)
    TestEq("NonceFresh case-sensitive", NonceFresh("AAAAAAAAAAAAAAAA|" t, a, t, 10), 0)
    TestEq("NonceFresh broken timestamp", NonceFresh(a "|soon", a, t, 10), 0)
    TestEq("NonceFresh missing timestamp", NonceFresh(a, a, t, 10), 0)
    TestEq("NonceAdd drops expired and malformed entries"
         , NonceAdd(a "|20260101110000,junk,zz|" t ",|," b "|" t, c, "20260101120500", 10, 4), c "|20260101120500," b "|" t)
    TestEq("NonceAdd keeps at most four"
         , NonceAdd(d "|" t "," c "|" t "," b "|" t "," a "|" t, e, t, 10, 4), e "|" t "," d "|" t "," c "|" t "," b "|" t)
    TestEq("NonceAdd same nonce again: once, with the new time", NonceAdd(two, a, "20260101120200", 10, 4)
         , a "|20260101120200," b "|20260101120100")
    TestEq("NonceAdd keep 1 replaces", NonceAdd(a "|" t, b, t, 2, 1), b "|" t)
}

TestTokenInfo() {
    i := TokenInfo('{"client_id":"abc123","login":"someone","scopes":[],"user_id":"42","expires_in":5184000}')
    TestEq("TokenInfo login", i.login, "someone")
    TestEq("TokenInfo clientId", i.clientId, "abc123")
    TestEq("TokenInfo expires", i.expires, 5184000)
    TestEq("TokenInfo without expires_in", TokenInfo('{"client_id":"abc","login":"x"}').expires, 0)
    ; a value containing an escaped quote: what the old regex got wrong
    TestEq("TokenInfo escaped quote", TokenInfo('{"client_id":"abc","login":"a\"b"}').login, 'a"b')
    for bad in ["", "<html>error</html>", "[]", '"login"', "{}", '{"login":"x"}', '{"client_id":"abc"}'
              , '{"client_id":"abc","login":""}', '{"client_id":"abc","login":5}', '{"client_id":7,"login":"x"}'
              , '{"client_id":"abc","login":["x"]}', '{"client_id":"abc","login":"x","expires_in":"soon"}'
              , '{"client_id":"abc","login":"x","expires_in":1.5}', '{"client_id":"abc","login":"x"']
        TestThrows("TokenInfo(" bad ") must fail", () => TokenInfo(bad))
}

TestChatTitle() {
    ; [title, channel, is it the chat?]
    for c in [["twitch.tv/popout/xqc/chat?darkpopout", "xqc", 1]
            , ["https://www.twitch.tv/popout/xqc/chat", "xqc", 1]
            , ["www.twitch.tv/popout/XQC/chat", "xqc", 1]
            , ["xQc - Chat - Twitch", "xqc", 1]
            , ["Chat - xqc", "xqc", 1]
            , ["some_one - Twitch", "some_one", 1]
            , ["Twitch", "xqc", 1]
            , [" twitch ", "xqc", 1]
            , ["ChatGPT", "a", 0]
            , ["ChatGPT", "xqc", 0]
            , ["ChatGPT - a new conversation", "a", 0]
            , ["A new tab", "a", 0]
            , ["Banana bread", "a", 0]
            , ["chat", "xqc", 0]
            , ["Live chat support", "xqc", 0]
            , ["xqc", "xqc", 0]
            , ["xqc - YouTube - Google Chrome", "xqc", 0]
            , ["twitch.tv/popout/xqcow/chat", "xqc", 0]
            , ["xqcow - Twitch", "xqc", 0]
            , ["Twitch - Google Chrome", "xqc", 0]
            , ["Twitch", "", 0]
            , ["Chat", "chat", 0]
            , ["Twitch - Brave", "twitch", 0]
            , ["twitch - Chat", "twitch", 1]
            , ["x.y chat", "x.y", 0]]
        TestEq("IsChatTitle(" c[1] ", " c[2] ")", IsChatTitle(c[1], c[2]) ? 1 : 0, c[3])
}

TestIsUnder() {
    TestEq("IsUnder inside", IsUnder("C:\ProgramData\chocolatey\bin", "C:\ProgramData"), 1)
    TestEq("IsUnder itself, other case, trailing backslashes", IsUnder("c:\programdata\", "C:\ProgramData\"), 1)
    TestEq("IsUnder name that only starts the same", IsUnder("C:\ProgramDataX\bin", "C:\ProgramData"), 0)
    TestEq("IsUnder elsewhere", IsUnder("C:\Program Files\mpv", "C:\ProgramData"), 0)
    TestEq("IsUnder parent", IsUnder("C:\Users", "C:\Users\Public"), 0)
    TestEq("IsUnder no root", IsUnder("C:\x", ""), 0)
}

#Include ..\app\puddock.ahk
