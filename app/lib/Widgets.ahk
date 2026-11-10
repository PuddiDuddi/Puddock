#Requires AutoHotkey v2.0
; Puddock — the launcher's controls: text field, checkbox, option row (part of puddock.ahk, included from there)
;
; Each one is placed by Launcher.Put(thing, x, y, w, h) -> thing.Place(L, x, y, w, h), in the
; launcher's own units (96-dpi pixels; L.S scales them), and lists its windows in Hwnds so the
; launcher can show a description for whatever the mouse is over.

; Padded text input: an Edit (and an optional fixed prefix like "twitch.tv/") inside its
; own small child window.
class Field {
    __New(L, cue := "", opt := "", prefix := "") {
        fr := this.fr := Gui("-Caption -DPIScale +E0x10000 +Parent" L.g.Hwnd)   ; WS_EX_CONTROLPARENT: Tab works
        fr.BackColor := T.input
        fr.MarginX := fr.MarginY := 0
        fr.SetFont("s10 c" T.text, FONT)
        this.pre := prefix = "" ? 0 : fr.AddText("x0 y0 w10 h10 +0x200 +0x100 c" T.dim, prefix)
        this.preW := StrLen(prefix) * 7.4 + 2                    ; Consolas 10 pt: a character is 7.33 px wide
        this.e := fr.AddEdit("x0 y0 w10 h10 -Multi -E0x200 Background" T.input " " opt)
        SetWindowTheme(this.e.Hwnd, "DarkMode_CFD")              ; lighter placeholder (cue) text
        if (cue != "")
            SendMessage(0x1501, 1, StrPtr(cue), this.e)          ; EM_SETCUEBANNER
        fr.Show("x0 y0 w10 h10 NA")
        L.Track(fr)
        L.fields.Push(this)
    }

    Place(L, x, y, w, h) {
        s := L.S, W := Round(w * s), H := Round(h * s)
        MoveWin(this.fr.Hwnd, Round(x * s), Round(y * s), W, H)
        pad := Round(12 * s), eh := Round(20 * s), pw := this.pre ? Round(this.preW * s) : 0
        if this.pre
            this.pre.Move(pad, 0, pw, H)
        this.e.Move(pad + pw, (H - eh) // 2, W - 2 * pad - pw, eh)
    }

    ; caret to the start, nothing selected, the start of the text in view
    Home() {
        SendMessage(0xB1, 0, 0, this.e)                          ; EM_SETSEL
        SendMessage(0xB7, 0, 0, this.e)                          ; EM_SCROLLCARET
    }

    Value {
        get => this.e.Value
        set => this.e.Value := value
    }

    Focus() => this.e.Focus()

    Hwnds => this.pre ? [this.e.Hwnd, this.pre.Hwnd, this.fr.Hwnd] : [this.e.Hwnd, this.fr.Hwnd]
}

; "[x] Label" — the box and the label both flip it
class Toggle {
    __New(L, label, help := "") {
        this.L := L, this._v := false
        flip := (*) => this.Value := !this._v
        this.box := L.Button("[ ]", flip, "plain")
        this.box.OnEvent("DoubleClick", flip)                    ; a quick second click is a DoubleClick, not a Click
        this.lbl := L.Add("Text", "x0 y0 w10 h10 +0x200 c" T.muted, label)
        this.lbl.OnEvent("Click", flip)
        this.lbl.OnEvent("DoubleClick", flip)
        L.Help(this, help)
    }

    Place(L, x, y, w, h) {
        L.Put(this.box, x, y, 32, h)
        L.Put(this.lbl, x + 40, y, w - 40, h)
    }

    Value {
        get => this._v
        set {
            this._v := !!value
            this.box.Text := this._v ? "[x]" : "[ ]"
            this.L.Paint(this.box, T.bg, T.input, this._v ? T.text : T.dim)
            this.lbl.SetFont("c" (this._v ? T.text : T.muted))
        }
    }

    Hwnds => [this.box.Hwnd, this.lbl.Hwnd]
}

; Row of options, one selected: the selected one sits on a raised surface, the others are plain text
class Segment {
    __New(L, items, labels, optW, help := "") {
        this.L := L, this.items := items, this.cs := [], this._v := "", this.w := optW
        for i, it in items {
            c := L.Button(labels[i], this.Pick.Bind(this, it), "plain")
            c.OnEvent("DoubleClick", this.Pick.Bind(this, it))
            this.cs.Push(c)
        }
        L.Help(this, help)
    }

    Pick(it, *) => this.Value := it

    Place(L, x, y, w, h) {
        for i, c in this.cs
            L.Put(c, x + (i - 1) * this.w, y, this.w - 4, h)
    }

    Value {
        get => this._v
        set {
            this._v := value
            for i, c in this.cs {
                on := this.items[i] = value
                this.L.Paint(c, on ? T.hover : T.bg, on ? T.hover : T.input, on ? T.text : T.dim)
            }
        }
    }

    Hwnds {
        get {
            out := []
            for c in this.cs
                out.Push(c.Hwnd)
            return out
        }
    }
}

; One line of the settings page: an optional label on the left, and `place(x, y, w)` for what
; stands to the right of the label column.
class Row {
    __New(lbl, place) {
        this.lbl := lbl, this.place := place
    }

    Put(L, x, y, fw) {
        if this.lbl
            L.Put(this.lbl, x, y, 160, 32)
        this.place.Call(x + 168, y, fw - 168)
    }
}
