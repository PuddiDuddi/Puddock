#Requires AutoHotkey v2.0
; ---------------------------------------------------------------------------
;  Minimal JSON for the native messaging channel (small, trusted-shape messages).
;    Json.Parse(text)      objects -> Map, arrays -> Array, true/false -> 1/0, null -> ""
;    Json.Stringify(value) Map / Array / plain Object / String / Integer / Float
;  Numbers come back as numbers, so the caller can tell 1 from "1" with `is Number`.
; ---------------------------------------------------------------------------

class Json {
    static MaxDepth := 16

    static Parse(text) {
        pos := 1
        value := Json._Value(text, &pos, 0)
        Json._Skip(text, &pos)
        if (pos <= StrLen(text))
            throw ValueError("JSON: unexpected data at position " pos)
        return value
    }

    static Stringify(value) {
        switch Type(value) {
            case "Map":
                out := ""
                for k, v in value
                    out .= (out = "" ? "" : ",") Json._Quote(String(k)) ":" Json.Stringify(v)
                return "{" out "}"
            case "Array":
                out := ""
                for v in value
                    out .= (A_Index = 1 ? "" : ",") Json.Stringify(v)
                return "[" out "]"
            case "Object":
                out := ""
                for k, v in value.OwnProps()
                    out .= (out = "" ? "" : ",") Json._Quote(k) ":" Json.Stringify(v)
                return "{" out "}"
            case "Integer", "Float":
                return String(value)
            default:
                return Json._Quote(String(value))
        }
    }

    static _Quote(s) {
        out := ""
        Loop Parse s {
            c := A_LoopField, n := Ord(c)
            if (c = '"')
                out .= '\"'
            else if (c = "\")
                out .= "\\"
            else if (n < 0x20)
                out .= n = 10 ? "\n" : n = 13 ? "\r" : n = 9 ? "\t" : Format("\u{:04x}", n)
            else
                out .= c
        }
        return '"' out '"'
    }

    static _Skip(t, &p) {
        while (p <= StrLen(t) && InStr(" `t`r`n", SubStr(t, p, 1), true))
            p++
    }

    static _Value(t, &p, depth) {
        if (depth > Json.MaxDepth)
            throw ValueError("JSON: nested too deeply")
        Json._Skip(t, &p)
        c := SubStr(t, p, 1)
        switch c {
            case "{":
                m := Map(), p++
                Json._Skip(t, &p)
                if (SubStr(t, p, 1) = "}") {
                    p++
                    return m
                }
                Loop {
                    Json._Skip(t, &p)
                    if (SubStr(t, p, 1) != '"')
                        throw ValueError("JSON: expected a key at position " p)
                    k := Json._String(t, &p)
                    Json._Skip(t, &p)
                    if (SubStr(t, p, 1) != ":")
                        throw ValueError("JSON: expected ':' at position " p)
                    p++
                    m[k] := Json._Value(t, &p, depth + 1)
                    Json._Skip(t, &p)
                    c := SubStr(t, p++, 1)
                    if (c = "}")
                        return m
                    if (c != ",")
                        throw ValueError("JSON: expected ',' or '}' at position " p - 1)
                }
            case "[":
                a := [], p++
                Json._Skip(t, &p)
                if (SubStr(t, p, 1) = "]") {
                    p++
                    return a
                }
                Loop {
                    a.Push(Json._Value(t, &p, depth + 1))
                    Json._Skip(t, &p)
                    c := SubStr(t, p++, 1)
                    if (c = "]")
                        return a
                    if (c != ",")
                        throw ValueError("JSON: expected ',' or ']' at position " p - 1)
                }
            case '"':
                return Json._String(t, &p)
            case "t":
                return Json._Literal(t, &p, "true", 1)
            case "f":
                return Json._Literal(t, &p, "false", 0)
            case "n":
                return Json._Literal(t, &p, "null", "")
            default:
                if !RegExMatch(t, "A)-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?", &m, p)
                    throw ValueError("JSON: unexpected character at position " p)
                p += m.Len
                return InStr(m[0], ".") || InStr(m[0], "e") || InStr(m[0], "E") ? Float(m[0]) : Integer(m[0])
        }
    }

    static _Literal(t, &p, word, value) {
        if (SubStr(t, p, StrLen(word)) !== word)
            throw ValueError("JSON: unexpected character at position " p)
        p += StrLen(word)
        return value
    }

    static _String(t, &p) {
        out := "", p++                                   ; skip the opening quote
        Loop {
            if (p > StrLen(t))
                throw ValueError("JSON: unterminated string")
            c := SubStr(t, p++, 1)
            if (c = '"')
                return out
            if (c != "\") {
                out .= c
                continue
            }
            e := SubStr(t, p++, 1)
            switch e, true {
                case '"', "\", "/": out .= e
                case "b": out .= Chr(8)
                case "f": out .= Chr(12)
                case "n": out .= "`n"
                case "r": out .= "`r"
                case "t": out .= "`t"
                case "u":
                    hex := SubStr(t, p, 4)
                    if !RegExMatch(hex, "^[0-9A-Fa-f]{4}$")
                        throw ValueError("JSON: bad \u escape at position " p)
                    out .= Chr(Integer("0x" hex)), p += 4
                default:
                    throw ValueError("JSON: bad escape at position " p - 1)
            }
        }
    }
}
