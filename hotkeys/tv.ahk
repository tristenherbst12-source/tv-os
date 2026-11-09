; TV Launcher hotkeys (AutoHotkey v2).
; - Home (remote):    leave the current app and bring the launcher back.
; - Back (remote):    a short press goes to the app as normal; holding it for 0.8 s also goes Home.
; - Escape hatch:     Ctrl+Alt+Shift+D by default: start the Windows desktop (asks for the PIN when one is set).
; - While the launcher is in front, every key is reported to the helper for the key-test page.
; Keys come from config/keymap.json ("global" section, AutoHotkey key names).

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
Persistent
SetTitleMatchMode 2

global Root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
global DataDir := EnvGet("LOCALAPPDATA") "\TVLauncher"
global ProfileLauncher := DataDir "\profiles\launcher"
global BackHoldSeconds := 0.8
global Pending := []          ; async requests in flight (kept so they are not cancelled)

; ---------- config ----------
ReadFile(path) {
    try return FileRead(path, "UTF-8")
    return ""
}

; Small reader for one string array in keymap.json: section -> key -> ["a", "b"].
JsonArray(txt, section, key) {
    out := []
    if !RegExMatch(txt, 's)"' section '"\s*:\s*\{(.*?)\}', &m)
        return out
    if !RegExMatch(m[1], 's)"' key '"\s*:\s*\[(.*?)\]', &a)
        return out
    pos := 1
    while (pos := RegExMatch(a[1], '"((?:[^"\\]|\\.)*)"', &s, pos)) {
        out.Push(StrReplace(StrReplace(s[1], '\"', '"'), "\\", "\"))
        pos += s.Len
    }
    return out
}

HelperInfo() {
    txt := ReadFile(DataDir "\helper.json")
    if !RegExMatch(txt, '"port"\s*:\s*(\d+)', &p) || !RegExMatch(txt, '"token"\s*:\s*"([^"]+)"', &t)
        return ""
    return {port: p[1], token: t[1]}
}

JsonStr(s) => '"' StrReplace(StrReplace(StrReplace(String(s), "\", "\\"), '"', '\"'), "`n", "\n") '"'

; ---------- talking to the helper ----------
HelperCall(method, path, body := "", async := false) {
    h := HelperInfo()
    if !h
        return ""
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open(method, "http://127.0.0.1:" h.port path, async)
        req.SetTimeouts(500, 500, 3000, 5000)
        req.SetRequestHeader("X-TV-Token", h.token)
        req.SetRequestHeader("Content-Type", "application/json")
        req.Send(body)
        if async {
            Pending.Push(req)
            if Pending.Length > 20
                Pending.RemoveAt(1)
            return ""
        }
        return req.ResponseText
    } catch {
        return ""
    }
}

; ---------- finding the launcher window ----------
CommandLine(pid) {
    try {
        for p in ComObjGet("winmgmts:").ExecQuery("SELECT CommandLine FROM Win32_Process WHERE ProcessId=" pid)
            return p.CommandLine
    }
    return ""
}

LauncherHwnd() {
    static cached := 0
    if (cached && WinExist(cached))
        return cached
    cached := 0
    for hwnd in WinGetList("ahk_exe msedge.exe") {
        try {
            if (WinGetTitle(hwnd) != "" && InStr(CommandLine(WinGetPID(hwnd)), ProfileLauncher)) {
                cached := hwnd
                break
            }
        }
    }
    return cached
}

LauncherActive(*) {
    a := WinExist("A")
    return a && a = LauncherHwnd()
}

ActivateLauncher() {
    if (lw := LauncherHwnd()) {
        WinActivate(lw)
        return
    }
    HelperCall("POST", "/restart-launcher")   ; no launcher window: have the helper start a fresh one
}

; ---------- Home ----------
WindowInfo(hwnd) {
    j := "{"
    try {
        cls := WinGetClass(hwnd)
        j .= '"hwnd":' hwnd ',"pid":' WinGetPID(hwnd) ',"exe":' JsonStr(WinGetProcessPath(hwnd)) ',"class":' JsonStr(cls)
        ; Store (UWP) apps live inside an ApplicationFrameHost window; the real app owns the CoreWindow child.
        if (cls = "ApplicationFrameWindow") {
            for c in WinGetControlsHwnd(hwnd) {
                if (WinGetClass(c) = "Windows.UI.Core.CoreWindow") {
                    j .= ',"coreExe":' JsonStr(WinGetProcessPath(c))
                    break
                }
            }
        }
    }
    return j "}"
}

GoHome(*) {
    hwnd := WinExist("A")
    if (hwnd && hwnd = LauncherHwnd())
        return
    action := "minimize"
    if hwnd {
        cls := ""
        try cls := WinGetClass(hwnd)
        if (cls = "Shell_TrayWnd" || cls = "Progman" || cls = "WorkerW")
            hwnd := 0
    }
    if hwnd {
        res := HelperCall("POST", "/home", WindowInfo(hwnd))
        if RegExMatch(res, '"action"\s*:\s*"(\w+)"', &m)
            action := m[1]
        try {
            if (action = "close")
                WinClose(hwnd)          ; polite close (WM_CLOSE), like clicking X
            else if (action = "minimize")
                WinMinimize(hwnd)
        }
    }
    ActivateLauncher()
}

; ---------- Back: short press passes through, long press goes Home ----------
BackPressed(hk) {
    key := RegExReplace(hk, "^[~$*]+")
    if KeyWait(key, "T" BackHoldSeconds) {
        Send("{" key "}")               ; released quickly: give the app its Back
    } else {
        GoHome()
        KeyWait(key)                    ; swallow the rest of the hold
    }
}

; ---------- escape hatch ----------
EscapeHatch(*) {
    pin := ""
    if InStr(HelperCall("GET", "/desktop"), '"pinRequired":true') {
        ib := InputBox("Enter the PIN to open the Windows desktop.", "Windows Desktop", "Password w320 h130")
        if (ib.Result != "OK")
            return
        pin := ib.Value
    }
    res := HelperCall("POST", "/desktop", '{"pin":' JsonStr(pin) '}')
    if InStr(res, "wrong pin")
        MsgBox("Wrong PIN.", "Windows Desktop", "Iconx T3")
}

; ---------- key feed for the key-test page ----------
OnKeyDown(ih, vk, sc) {
    if !LauncherActive()
        return
    name := GetKeyName(Format("vk{:x}sc{:x}", vk, sc))
    HelperCall("POST", "/keys", '{"name":' JsonStr(name) ',"vk":' vk ',"sc":' sc '}', true)
}

; ---------- wire it up ----------
km := ReadFile(Root "\config\keymap.json")

HotIf((*) => !LauncherActive())
for k in JsonArray(km, "global", "home")
    try Hotkey("$" k, GoHome)
for k in JsonArray(km, "global", "back")
    try Hotkey("$" k, BackPressed)
HotIf()
for k in JsonArray(km, "global", "escapeHatch")
    try Hotkey("$" k, EscapeHatch)

ih := InputHook("V L0 I")
ih.KeyOpt("{All}", "N")
ih.OnKeyDown := OnKeyDown
ih.Start()
