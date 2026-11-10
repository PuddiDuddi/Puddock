#Requires AutoHotkey v2.0
; Puddock — child processes, the token pipe, argument quoting (part of puddock.ahk, included from there)

; ---------- child processes ----------
; streamlink is started WITHOUT a shell, suspended, put into a job object that dies with us, then
; resumed. So closing Puddock (even from Task Manager) also ends streamlink and the mpv it starts,
; we never act on a bare PID that Windows may have handed to someone else, and we can tell exactly
; which processes are "ours" (Owns) — used to hand out the token and to accept mpv's window.
class ChildProcess {
    __New(cmdLine, logPath) {
        this.hProcess := 0, this.job := 0, this.pid := 0
        sa := Buffer(A_PtrSize * 3, 0)                          ; SECURITY_ATTRIBUTES, inheritable
        NumPut("UInt", sa.Size, sa, 0), NumPut("Int", 1, sa, A_PtrSize * 2)
        hLog := DllCall("CreateFile", "Str", logPath, "UInt", 0x40000000, "UInt", 3, "Ptr", sa
                      , "UInt", 2, "UInt", 0x80, "Ptr", 0, "Ptr")    ; GENERIC_WRITE, CREATE_ALWAYS
        if (hLog = -1)
            throw OSError(A_LastError, , "log file " logPath)
        x64 := A_PtrSize = 8
        ; STARTUPINFOEXW = STARTUPINFOW (104 / 68 bytes) + lpAttributeList. The attribute list names
        ; the ONE handle the child may inherit (the log): without it, bInheritHandles = true hands
        ; over every inheritable handle this process happens to hold.
        siSize := x64 ? 104 : 68
        si := Buffer(siSize + A_PtrSize, 0)
        NumPut("UInt", 0x101, si, x64 ? 60 : 44)                ; STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW
        NumPut("Ptr", hLog, "Ptr", hLog, si, x64 ? 88 : 60)     ; hStdOutput, hStdError (wShowWindow = SW_HIDE)
        pi := Buffer(A_PtrSize * 2 + 8, 0)                      ; PROCESS_INFORMATION
        cl := Buffer(StrPut(cmdLine) * 2)
        StrPut(cmdLine, cl)
        handles := Buffer(A_PtrSize), NumPut("Ptr", hLog, handles)   ; must stay alive until the list is deleted
        attrs := 0, size := 0
        DllCall("InitializeProcThreadAttributeList", "Ptr", 0, "UInt", 1, "UInt", 0, "UPtr*", &size)   ; asks for the size
        if size {
            attrs := Buffer(size, 0)
            if !DllCall("InitializeProcThreadAttributeList", "Ptr", attrs, "UInt", 1, "UInt", 0, "UPtr*", &size)
                attrs := 0
            else if !DllCall("UpdateProcThreadAttribute", "Ptr", attrs, "UInt", 0, "UPtr", 0x20002   ; PROC_THREAD_ATTRIBUTE_HANDLE_LIST
                           , "Ptr", handles, "UPtr", handles.Size, "Ptr", 0, "Ptr", 0) {
                DllCall("DeleteProcThreadAttributeList", "Ptr", attrs)
                attrs := 0
            }
        }
        ok := false, this.handleList := false
        if attrs {
            NumPut("UInt", si.Size, si, 0)                      ; cb says it's the EX structure (112 / 72)
            NumPut("Ptr", attrs.Ptr, si, siSize)
            ok := DllCall("CreateProcess", "Ptr", 0, "Ptr", cl, "Ptr", 0, "Ptr", 0, "Int", true   ; CREATE_NO_WINDOW
                        , "UInt", 0x08080004, "Ptr", 0, "Ptr", 0, "Ptr", si, "Ptr", pi)   ; | EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED
            err := A_LastError
            DllCall("DeleteProcThreadAttributeList", "Ptr", attrs)
            this.handleList := ok
        }
        if !ok {                                                ; no attribute list (or refused with it): the plain way
            NumPut("UInt", siSize, si, 0)
            StrPut(cmdLine, cl)                                 ; CreateProcess may have modified the buffer
            ok := DllCall("CreateProcess", "Ptr", 0, "Ptr", cl, "Ptr", 0, "Ptr", 0, "Int", true
                        , "UInt", 0x08000004, "Ptr", 0, "Ptr", 0, "Ptr", si, "Ptr", pi)   ; CREATE_NO_WINDOW | CREATE_SUSPENDED
            err := A_LastError
        }
        DllCall("CloseHandle", "Ptr", hLog)
        if !ok
            throw OSError(err, , "streamlink")
        this.hProcess := NumGet(pi, 0, "Ptr"), hThread := NumGet(pi, A_PtrSize, "Ptr")
        this.pid := NumGet(pi, A_PtrSize * 2, "UInt")
        ; JOBOBJECT_EXTENDED_LIMIT_INFORMATION with LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        job := DllCall("CreateJobObject", "Ptr", 0, "Ptr", 0, "Ptr")
        info := Buffer(x64 ? 144 : 112, 0)
        NumPut("UInt", 0x2000, info, 16)
        if job && DllCall("SetInformationJobObject", "Ptr", job, "Int", 9, "Ptr", info, "UInt", info.Size)
              && DllCall("AssignProcessToJobObject", "Ptr", job, "Ptr", this.hProcess)
            this.job := job
        else if job
            DllCall("CloseHandle", "Ptr", job)
        DllCall("ResumeThread", "Ptr", hThread)
        DllCall("CloseHandle", "Ptr", hThread)
    }

    Running => this.hProcess && DllCall("WaitForSingleObject", "Ptr", this.hProcess, "UInt", 0) = 258   ; WAIT_TIMEOUT

    ; is `pid` streamlink itself or anything it started (mpv)?
    Owns(pid) {
        if !pid
            return false
        if !this.job
            return pid = this.pid
        h := DllCall("OpenProcess", "UInt", 0x1000, "Int", false, "UInt", pid, "Ptr")   ; QUERY_LIMITED_INFORMATION
        if !h
            return false
        inJob := 0
        DllCall("IsProcessInJob", "Ptr", h, "Ptr", this.job, "Int*", &inJob)
        DllCall("CloseHandle", "Ptr", h)
        return inJob != 0
    }

    Kill() {
        if this.job
            DllCall("TerminateJobObject", "Ptr", this.job, "UInt", 1)
        else if this.Running
            DllCall("TerminateProcess", "Ptr", this.hProcess, "UInt", 1)
    }

    __Delete() {
        for h in [this.hProcess, this.job]
            if h
                DllCall("CloseHandle", "Ptr", h)
    }
}

; The browser runs its native host in a job that is killed when the host exits (Firefox does,
; at least). The player must outlive that short-lived helper, so leave the job when allowed.
LaunchDetached(cmdLine) {
    for flags in [0x01000000, 0] {                              ; CREATE_BREAKAWAY_FROM_JOB, then plain
        si := Buffer(A_PtrSize = 8 ? 104 : 68, 0)
        NumPut("UInt", si.Size, si, 0)
        pi := Buffer(A_PtrSize * 2 + 8, 0)
        cl := Buffer(StrPut(cmdLine) * 2)
        StrPut(cmdLine, cl)
        if DllCall("CreateProcess", "Ptr", 0, "Ptr", cl, "Ptr", 0, "Ptr", 0, "Int", false
                 , "UInt", flags, "Ptr", 0, "Ptr", 0, "Ptr", si, "Ptr", pi) {
            DllCall("CloseHandle", "Ptr", NumGet(pi, 0, "Ptr"))
            DllCall("CloseHandle", "Ptr", NumGet(pi, A_PtrSize, "Ptr"))
            return true
        }
    }
    return false
}

; ---------- token hand-off to streamlink ----------
; streamlink reads extra arguments from "@<file>" (argparse). We give it "@\\.\pipe\puddock-<random>"
; instead of a file: the token never touches the disk or a command line, the pipe accepts only this
; Windows user and no network clients, and its content goes only to processes inside streamlink's
; job (checked per connection). streamlink parses its arguments twice (again once the Twitch
; plugin is loaded), so the pipe keeps answering until the player sees the stream list, then closes.
class SecretPipe {
    __New(text) {
        this.name := "\\.\pipe\puddock-" RandomHex(16), this.text := text, this.served := 0
        this.draining := []                                       ; answered instances, waiting to be read
        this.sa := UserOnlySecurity()
        this.h := this.NewInstance(true)
    }

    NewInstance(first) {
        h := DllCall("CreateNamedPipe", "Str", this.name
                   , "UInt", 0x2 | (first ? 0x80000 : 0)          ; OUTBOUND (+ FIRST_PIPE_INSTANCE: no squatting)
                   , "UInt", 0x9                                  ; BYTE | NOWAIT | REJECT_REMOTE_CLIENTS
                   , "UInt", 4, "UInt", 4096, "UInt", 0, "UInt", 0, "Ptr", this.sa.buf, "Ptr")
        if (h = -1)
            throw OSError(A_LastError, , "named pipe")
        return h
    }

    ; poll from a timer: answer a waiting client if it belongs to `child`
    Serve(child) {
        static flush := DllCall("GetProcAddress", "Ptr", DllCall("GetModuleHandle", "Str", "kernel32", "Ptr")
                              , "AStr", "FlushFileBuffers", "Ptr")
        this.Drain()
        if !this.h
            return
        ok := DllCall("ConnectNamedPipe", "Ptr", this.h, "Ptr", 0), err := A_LastError
        if ok || err = 536                                        ; just (re)armed / ERROR_PIPE_LISTENING
            return
        if (err != 535 && err != 232)                             ; ERROR_PIPE_CONNECTED / ERROR_NO_DATA
            return
        try next := this.NewInstance(false)                       ; keep the name answering
        catch                                                     ; all instances busy: again on the next poll
            return
        pid := 0, h := this.h
        this.h := next
        if (err = 535 && DllCall("GetNamedPipeClientProcessId", "Ptr", h, "UInt*", &pid) && child.Owns(pid)) {
            n := StrPut(this.text, "UTF-8") - 1, buf := Buffer(n + 1), written := 0
            StrPut(this.text, buf, n + 1, "UTF-8")
            DllCall("WriteFile", "Ptr", h, "Ptr", buf, "UInt", n, "UInt*", &written, "Ptr", 0)
            try DllCall("RtlZeroMemory", "Ptr", buf, "UPtr", buf.Size)
            this.served++
            ; The instance may be closed only once the client has read the text (closing earlier can
            ; throw it away), and that is what FlushFileBuffers waits for — forever, if the client
            ; never reads. So it waits on a bare helper thread (FlushFileBuffers itself is the thread
            ; function: one pointer-sized argument, the handle) and Drain() closes the instance when
            ; it is done or 2 s have passed. Nothing else touches the handle while the thread runs.
            if flush && (th := DllCall("CreateThread", "Ptr", 0, "UPtr", 0, "Ptr", flush, "Ptr", h, "UInt", 0, "Ptr", 0, "Ptr")) {
                this.draining.Push({h: h, thread: th, at: A_TickCount})
                return
            }
        }
        DllCall("CloseHandle", "Ptr", h)                          ; close, not disconnect: a clean EOF for Python
    }

    ; Close the instances whose text has been read (their flush returned) or that are overdue.
    Drain(now := false) {
        i := this.draining.Length
        while (i >= 1) {
            d := this.draining[i--]
            done := DllCall("WaitForSingleObject", "Ptr", d.thread, "UInt", 0) = 0
            if !done {
                if !now && A_TickCount - d.at < 2000
                    continue
                ; A client that doesn't read. Closing the handle under a pending flush would block
                ; just the same, so cancel the flush first; it ends right away.
                DllCall("CancelSynchronousIo", "Ptr", d.thread)
                done := DllCall("WaitForSingleObject", "Ptr", d.thread, "UInt", 500) = 0
            }
            DllCall("CloseHandle", "Ptr", d.thread)
            if done                                               ; else (not expected): leak it rather than hang
                DllCall("CloseHandle", "Ptr", d.h)                ; close, not disconnect: a clean EOF for Python
            this.draining.RemoveAt(i + 1)
        }
    }

    Close() {
        this.Drain(true)
        if this.h
            DllCall("CloseHandle", "Ptr", this.h)
        this.h := 0, this.text := ""
        if this.sa.psd
            DllCall("LocalFree", "Ptr", this.sa.psd)
        this.sa.psd := 0
    }
}

; SECURITY_ATTRIBUTES whose DACL grants access to the current user only (protected, nothing inherited)
UserOnlySecurity() {
    psd := 0
    if !DllCall("advapi32\ConvertStringSecurityDescriptorToSecurityDescriptorW"
              , "Str", "D:P(A;;GA;;;" CurrentUserSid() ")", "UInt", 1, "Ptr*", &psd, "Ptr", 0)
        throw OSError(A_LastError, , "security descriptor")
    buf := Buffer(A_PtrSize * 3, 0)
    NumPut("UInt", buf.Size, buf, 0), NumPut("Ptr", psd, buf, A_PtrSize)
    return {buf: buf, psd: psd}
}

CurrentUserSid() {
    hTok := 0, size := 0, str := 0
    DllCall("advapi32\OpenProcessToken", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt", 0x8, "Ptr*", &hTok)  ; TOKEN_QUERY
    DllCall("advapi32\GetTokenInformation", "Ptr", hTok, "Int", 1, "Ptr", 0, "UInt", 0, "UInt*", &size)  ; TokenUser
    info := Buffer(size)
    ok := DllCall("advapi32\GetTokenInformation", "Ptr", hTok, "Int", 1, "Ptr", info, "UInt", size, "UInt*", &size)
    DllCall("CloseHandle", "Ptr", hTok)
    if !ok || !DllCall("advapi32\ConvertSidToStringSidW", "Ptr", NumGet(info, 0, "Ptr"), "Ptr*", &str)
        throw OSError(A_LastError, , "user SID")
    sid := StrGet(str)
    DllCall("LocalFree", "Ptr", str)
    return sid
}

WindowPid(h) {
    pid := 0
    DllCall("GetWindowThreadProcessId", "Ptr", h, "UInt*", &pid)
    return pid
}

; One argument, quoted the way CommandLineToArgvW / the C runtime / Python read it back:
; backslashes are only special right before a quote, so double those and escape the quote.
ArgQuote(s) {
    s := String(s)
    if (s != "" && !RegExMatch(s, '[ \t\n\v"]'))
        return s
    out := '"', bs := 0
    Loop Parse s {
        c := A_LoopField
        if (c = "\") {
            bs++
            continue
        }
        out .= c = '"' ? StrRepeat("\", bs * 2 + 1) '"' : StrRepeat("\", bs) c
        bs := 0
    }
    return out StrRepeat("\", bs * 2) '"'
}

StrRepeat(s, n) {
    out := ""
    Loop n
        out .= s
    return out
}


