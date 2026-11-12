; TV Launcher hotkeys (AutoHotkey v2).
; - Home (remote):    leave the current app and bring the launcher back (on the launcher itself: its own Home).
; - Back (remote):    a short press goes to the app as normal; holding it for 0.8 s also goes Home.
; - Blocked keys:     e.g. the remote's Search button, which would otherwise open a web search.
; - Pointer:          hidden while the remote's buttons are used (not with -Windowed).
; - Volume keys:      change the volume, with a small volume bar (not with -Windowed). Windows normally does this
;                     in Explorer, which does not run on the TV, so without this the volume buttons do nothing.
; - Escape hatch:     Ctrl+Alt+Shift+D by default: start the Windows desktop (asks for the PIN when one is set).
; - While the launcher is in front, every key is reported to the helper for the key-test page.
; Keys come from config/keymap.json ("global" section, AutoHotkey key names).
;   AutoHotkey64.exe tv.ahk [-Windowed]     (-Windowed: testing on a desktop PC, see scripts/start.ps1)

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
; Timed from the key-down to the key-up event. (KeyWait cannot be used: the hotkey blocks the key, so its
; logical state never changes.) Auto-repeat key-downs while held are ignored.
global BackState := Map()           ; key -> "down" | "fired"

BackDown(hk) {
    key := RegExReplace(hk, "^[~$*]+")
    if BackState.Has(key)
        return                          ; auto-repeat
    BackState[key] := "down"
    SetTimer(BackHeld.Bind(key), -Round(BackHoldSeconds * 1000))
}

BackHeld(key) {
    if (BackState.Has(key) && BackState[key] = "down") {
        BackState[key] := "fired"
        GoHome()
    }
}

BackUp(hk) {
    key := RegExReplace(hk, "^[~$*]+|\s+up$")
    state := BackState.Has(key) ? BackState.Delete(key) : ""
    if (state = "down")
        Send("{" key "}")               ; released quickly: give the app its Back
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

; ---------- Home key ----------
; Always caught. On the launcher it becomes F24 (the page treats it as Home): left alone, Edge would act on
; Browser_Home itself and open its own home page inside the launcher window, with no way back.
HomeKey(*) {
    if LauncherActive()
        Send("{F24}")
    else
        GoHome()
}

; ---------- which windows Back is handled in ----------
; On the TV every app is one of our windows, so Back works everywhere. With -Windowed (testing on a desktop PC)
; it only applies to the TV windows, so Backspace keeps working normally in the PC's own programs.
TVWindowActive(*) {
    static lastHwnd := 0, lastResult := false
    hwnd := WinExist("A")
    if !hwnd
        return false
    if (hwnd = lastHwnd)
        return lastResult
    lastHwnd := hwnd
    lastResult := false
    try lastResult := InStr(CommandLine(WinGetPID(hwnd)), DataDir "\profiles\") > 0
    return lastResult
}
BackApplies(*) => !LauncherActive() && (!Windowed || TVWindowActive())

; ---------- hide the pointer while the remote buttons are used (TV only, not with -Windowed) ----------
; The touchpad only moves the pointer when touched, so: hidden on any key press or after 3 s without moving,
; shown again (where it was) as soon as it moves. While hidden it is parked in the bottom-right corner, so web
; pages do not keep showing hover previews under it.
global PointerHidden := false, PointerX := 0, PointerY := 0
global ParkX := 0, ParkY := 0

SetBlankCursors() {
    ; Every standard cursor shape replaced by an empty one (restored with SPI_SETCURSORS).
    for id in [32512, 32513, 32514, 32515, 32516, 32640, 32641, 32642, 32643, 32644, 32645, 32646, 32648, 32649, 32650, 32651] {
        andMask := Buffer(128, 0xFF), xorMask := Buffer(128, 0)
        h := DllCall("CreateCursor", "Ptr", 0, "Int", 0, "Int", 0, "Int", 32, "Int", 32, "Ptr", andMask, "Ptr", xorMask, "Ptr")
        DllCall("SetSystemCursor", "Ptr", h, "UInt", id)
    }
}
RestoreCursors(*) => DllCall("SystemParametersInfo", "UInt", 0x57, "UInt", 0, "Ptr", 0, "UInt", 0)

HidePointer() {
    global PointerHidden, PointerX, PointerY, ParkX, ParkY
    if PointerHidden
        return
    CoordMode("Mouse", "Screen")
    MouseGetPos(&PointerX, &PointerY)
    SetBlankCursors()
    ParkX := A_ScreenWidth - 1, ParkY := A_ScreenHeight - 1
    DllCall("SetCursorPos", "Int", ParkX, "Int", ParkY)
    PointerHidden := true
}

; Only real touchpad use counts (A_TimeIdleMouse ignores input made by programs), so nothing but the touchpad
; brings the pointer back.
CheckPointer() {
    global PointerHidden
    touched := A_TimeIdleMouse < 200
    if PointerHidden {
        if touched {
            CoordMode("Mouse", "Screen")
            MouseGetPos(&x, &y)
            if (Abs(x - ParkX) < 400 && Abs(y - ParkY) < 400)   ; still parked: back to where it was
                DllCall("SetCursorPos", "Int", PointerX + (x - ParkX), "Int", PointerY + (y - ParkY))
            RestoreCursors()
            PointerHidden := false
        }
    } else if (A_TimeIdleMouse > 3000) {
        HidePointer()
    }
}

; ---------- volume keys (TV only) ----------
; The volume pop-up: a dark pill near the top of the screen (clear of subtitles), with a speaker icon that shows the
; level, a slim bar and the number. Fades in and out; never takes focus, clicks pass through it.
global VolGui := 0, VolIcon := 0, VolTrack := 0, VolFill := 0, VolNum := 0, VolAlpha := 0
global VolW := 470, VolH := 84, VolBarX := 96, VolBarW := 276
global VolFadeIn := FadeVolume.Bind(+1), VolFadeOut := FadeVolume.Bind(-1)
VolumeKey(step, *) {
    if (step = 0)
        SoundSetMute(-1)
    else {
        if SoundGetMute()
            SoundSetMute(false)
        SoundSetVolume((step > 0 ? "+" : "") step)
    }
    ShowVolume()
}
ShowVolume() {
    global VolGui, VolIcon, VolTrack, VolFill, VolNum
    if !VolGui {
        VolGui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x20 +E0x08000000")   ; click-through, no focus
        VolGui.BackColor := "121826"
        VolGui.MarginX := 0, VolGui.MarginY := 0
        VolGui.SetFont("s25 cFFFFFF", "Segoe MDL2 Assets")                ; Windows' own icon font (speaker)
        VolIcon := VolGui.Add("Text", "x32 y" (VolH - 40) // 2 " w50 h40 BackgroundTrans", "")
        ; The bar: a dim track with a white fill on top (plain colour blocks, so it stays crisp on any GPU).
        VolTrack := VolGui.Add("Text", "x" VolBarX " y" (VolH - 6) // 2 " w" VolBarW " h6 Background3A4560")
        VolFill := VolGui.Add("Text", "x" VolBarX " y" (VolH - 6) // 2 " w1 h6 BackgroundFFFFFF")
        VolGui.SetFont("s17 w600 cFFFFFF", "Segoe UI")
        VolNum := VolGui.Add("Text", "x" (VolBarX + VolBarW + 12) " y" (VolH - 34) // 2 " w58 h34 Right BackgroundTrans", "")
        VolGui.Show("Hide w" VolW " h" VolH)
        DllCall("SetWindowRgn", "Ptr", VolGui.Hwnd, "Ptr", DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", VolW + 1, "Int", VolH + 1, "Int", VolH, "Int", VolH, "Ptr"), "Int", true)
        WinSetTransparent(0, VolGui.Hwnd)
    }
    muted := SoundGetMute(), level := Round(SoundGetVolume())
    ; Speaker with 0-3 waves by level (Segoe MDL2: E992-E995), crossed out when muted (E74F).
    VolIcon.Value := Chr(muted ? 0xE74F : level = 0 ? 0xE992 : level < 34 ? 0xE993 : level < 67 ? 0xE994 : 0xE995)
    fill := muted ? 0 : Round(VolBarW * level / 100)
    VolFill.Visible := fill > 0
    if fill
        VolFill.Move(, , fill)
    VolNum.Value := muted ? "" : level
    VolTrack.Opt("+Redraw"), VolFill.Opt("+Redraw")
    VolGui.Show("NA x" (A_ScreenWidth - VolW) // 2 " y" Round(A_ScreenHeight * 0.06))
    SetTimer(VolFadeOut, 0)
    SetTimer(VolFadeIn, 15)
    SetTimer(HideVolume, -1700)
}
; Fades the pop-up in (dir +1, to 235) or out (dir -1, then hides it), a few steps every 15 ms.
FadeVolume(dir) {
    global VolAlpha
    VolAlpha := Max(0, Min(235, VolAlpha + dir * 47))
    try WinSetTransparent(VolAlpha, VolGui.Hwnd)
    if (dir > 0 && VolAlpha >= 235) || (dir < 0 && VolAlpha <= 0) {
        SetTimer(, 0)
        if (dir < 0)
            VolGui.Hide()
    }
}
HideVolume() {
    if VolGui {
        SetTimer(VolFadeIn, 0)
        SetTimer(VolFadeOut, 15)
    }
}

; ---------- key feed for the key-test page ----------
OnKeyDown(ih, vk, sc) {
    if !Windowed
        HidePointer()
    if !LauncherActive()
        return
    name := GetKeyName(Format("vk{:x}sc{:x}", vk, sc))
    HelperCall("POST", "/keys", '{"name":' JsonStr(name) ',"vk":' vk ',"sc":' sc '}', true)
}

; ---------- wire it up ----------
global Windowed := false
for a in A_Args
    if (a = "-Windowed")
        Windowed := true

km := ReadFile(Root "\config\keymap.json")

for k in JsonArray(km, "global", "home")
    try Hotkey("$" k, HomeKey)
for k in JsonArray(km, "global", "block")
    try Hotkey("$" k, (*) => 0)
HotIf(BackApplies)
for k in JsonArray(km, "global", "back")
    try Hotkey("$" k, BackDown)
HotIf()
; Key-up is watched everywhere and always let through (~): a hold that ends on the launcher must still be cleared.
for k in JsonArray(km, "global", "back")
    try Hotkey("~$" k " up", BackUp)
for k in JsonArray(km, "global", "escapeHatch")
    try Hotkey("$" k, EscapeHatch)

ih := InputHook("V L0 I")
ih.KeyOpt("{All}", "N")
ih.OnKeyDown := OnKeyDown
ih.Start()

if !Windowed {
    InstallMouseHook()                  ; needed for A_TimeIdleMouse
    OnExit(RestoreCursors)
    SetTimer(CheckPointer, 150)
    ; Volume keys: only on the TV (on a normal PC, Windows' own volume keys and display stay in charge).
    for k in JsonArray(km, "global", "volumeUp")
        try Hotkey("$" k, VolumeKey.Bind(2))
    for k in JsonArray(km, "global", "volumeDown")
        try Hotkey("$" k, VolumeKey.Bind(-2))
    for k in JsonArray(km, "global", "mute")
        try Hotkey("$" k, VolumeKey.Bind(0))
}
