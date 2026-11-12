; TV Launcher hotkeys (AutoHotkey v2).
; - Home (remote):    leave the current app and bring the launcher back (on the launcher itself: its own Home).
; - Back (remote):    a short press goes to the app as normal; holding it for 0.8 s also goes Home.
; - Blocked keys:     e.g. the remote's Search button, which would otherwise open a web search.
; - Pointer:          hidden while the remote's buttons are used (not with -Windowed).
; - Volume keys:      change the volume, with a small volume bar (not with -Windowed). Windows normally does this
;                     in Explorer, which does not run on the TV, so without this the volume buttons do nothing.
; - Standby:        tells the helper when a real button press, click or pointer movement should end standby.
; - Escape hatch:    Ctrl+Alt+Shift+D by default: start the Windows desktop (asks for the PIN when one is set).
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
    if InStandby
        return
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
; The volume pop-up, drawn like the launcher's glass pills: a dark translucent pill with a soft shadow and a light
; edge, a speaker icon that shows the level, a blue bar with a glow and a knob, and the number. Drawn with GDI+
; into a per-pixel-alpha window (smooth edges, nothing behind shows through the text), near the top of the screen
; (clear of subtitles). Fades in and out; never takes focus, clicks pass through it.
global VolGui := 0, VolAlpha := 0, VolDC := 0, VolBmp := 0, VolOldBmp := 0, VolGdip := 0
global VolS := A_ScreenHeight / 1080                       ; drawn for 1080p, scaled for other screens
global VolPad := Round(26 * VolS)                          ; room around the pill for its shadow
global VolPillW := Round(500 * VolS), VolPillH := Round(88 * VolS)
global VolW := VolPillW + 2 * VolPad, VolH := VolPillH + 2 * VolPad
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
    global VolGui
    if !VolGui {
        ; WS_EX_LAYERED (per-pixel alpha) + click-through + never activated.
        VolGui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x80000 +E0x20 +E0x08000000")
        VolGui.Show("NA Hide w" VolW " h" VolH)
        VolSetUp()
    }
    muted := SoundGetMute(), level := Round(SoundGetVolume())
    VolDraw(level, muted)
    VolGui.Show("NA")
    VolPresent()
    SetTimer(VolFadeOut, 0)
    SetTimer(VolFadeIn, 15)
    SetTimer(HideVolume, -1800)
}

; ---- drawing (GDI+ flat API) ----
VolSetUp() {
    global VolDC, VolBmp, VolOldBmp, VolGdip
    DllCall("LoadLibrary", "Str", "gdiplus")
    si := Buffer(24, 0), NumPut("UInt", 1, si)
    DllCall("gdiplus\GdiplusStartup", "UPtr*", &tok := 0, "Ptr", si, "Ptr", 0)
    VolGdip := tok
    VolDC := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0), NumPut("Int", VolW, bi, 4), NumPut("Int", -VolH, bi, 8)
    NumPut("UShort", 1, bi, 12), NumPut("UShort", 32, bi, 14)
    VolBmp := DllCall("CreateDIBSection", "Ptr", VolDC, "Ptr", bi, "UInt", 0, "Ptr*", &bits := 0, "Ptr", 0, "UInt", 0, "Ptr")
    VolOldBmp := DllCall("SelectObject", "Ptr", VolDC, "Ptr", VolBmp, "Ptr")
}

VolRect(x, y, w, h) {
    r := Buffer(16), NumPut("Float", x, "Float", y, "Float", w, "Float", h, r)
    return r
}
VolRoundPath(x, y, w, h, rad) {
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &p := 0)
    d := rad * 2
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x, "Float", y, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x + w - d, "Float", y, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x, "Float", y + h - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", p)
    return p
}
VolFillRound(g, argb, x, y, w, h, rad) {
    p := VolRoundPath(x, y, w, h, rad)
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &b := 0)
    DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", b, "Ptr", p)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", b), DllCall("gdiplus\GdipDeletePath", "Ptr", p)
}
VolText(g, text, family, px, weightBold, argb, x, y, w, h, align) {
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", family, "Ptr", 0, "Ptr*", &fam := 0)
    if !fam
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Segoe UI", "Ptr", 0, "Ptr*", &fam := 0)
    DllCall("gdiplus\GdipCreateFont", "Ptr", fam, "Float", px, "Int", weightBold ? 1 : 0, "Int", 2, "Ptr*", &font := 0)
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0x1000, "Int", 0, "Ptr*", &fmt := 0)   ; 0x1000: no clipping
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmt, "Int", align)                  ; 0 left, 1 centre, 2 right
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)                  ; centred vertically
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &b := 0)
    DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", text, "Int", -1, "Ptr", font, "Ptr", VolRect(x, y, w, h), "Ptr", fmt, "Ptr", b)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", b), DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmt)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", font), DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", fam)
}

VolDraw(level, muted) {
    s := VolS, x0 := VolPad, y0 := VolPad, w := VolPillW, h := VolPillH, rad := h / 2
    DllCall("gdiplus\GdipCreateFromHDC", "Ptr", VolDC, "Ptr*", &g := 0)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)              ; anti-aliased shapes
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 4)          ; anti-aliased text (works on alpha)
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0)

    ; Soft shadow: a few widening, fading copies of the pill under it.
    loop 8 {
        e := (9 - A_Index) * 2.6 * s
        VolFillRound(g, (Round(6 + A_Index * 2.2) << 24), x0 - e, y0 - e + 6 * s, w + 2 * e, h + 2 * e, rad + e)
    }
    ; The pill: a deep blue-grey glass gradient, nearly opaque so the picture behind does not fight the text.
    p := VolRoundPath(x0, y0, w, h, rad)
    DllCall("gdiplus\GdipCreateLineBrushFromRect", "Ptr", VolRect(x0, y0, w, h), "UInt", 0xF2262F4A, "UInt", 0xF2121726, "Int", 1, "Int", 0, "Ptr*", &lb := 0)
    DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", lb, "Ptr", p)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", lb)
    ; A light edge, brighter along the top, as on the launcher's glass.
    DllCall("gdiplus\GdipCreateLineBrushFromRect", "Ptr", VolRect(x0, y0, w, h), "UInt", 0x66FFFFFF, "UInt", 0x14FFFFFF, "Int", 1, "Int", 0, "Ptr*", &eb := 0)
    DllCall("gdiplus\GdipCreatePen2", "Ptr", eb, "Float", 1.4 * s, "Int", 2, "Ptr*", &pen := 0)
    DllCall("gdiplus\GdipDrawPath", "Ptr", g, "Ptr", pen, "Ptr", p)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen), DllCall("gdiplus\GdipDeleteBrush", "Ptr", eb), DllCall("gdiplus\GdipDeletePath", "Ptr", p)

    ; Speaker icon (Windows' own icon font): 0-3 waves by level, crossed out when muted.
    icon := Chr(muted ? 0xE74F : level = 0 ? 0xE992 : level < 34 ? 0xE993 : level < 67 ? 0xE994 : 0xE995)
    VolText(g, icon, "Segoe MDL2 Assets", 36 * s, false, muted ? 0xFFFF8A9C : 0xFFFFFFFF, x0 + 26 * s, y0, 52 * s, h, 1)

    ; The bar: a dim track, then the level in blue with a soft glow and a white knob.
    bx := x0 + 98 * s, bw := 300 * s, bh := 8 * s, by := y0 + (h - bh) / 2
    if muted {                                                            ; no bar: just the word
        VolText(g, "Muted", "Segoe UI", 26 * s, true, 0xFFFFFFFF, bx, y0, bw, h, 0)
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
        return
    }
    VolFillRound(g, 0x2EFFFFFF, bx, by, bw, bh, bh / 2)
    fill := muted ? 0 : bw * level / 100
    if (fill > 0) {
        loop 4 {                                                          ; glow
            e := (5 - A_Index) * 2.2 * s
            VolFillRound(g, ((10 + A_Index * 9) << 24) | 0x508CFF, bx - e, by - e, fill + 2 * e, bh + 2 * e, bh / 2 + e)
        }
        DllCall("gdiplus\GdipCreateLineBrushFromRect", "Ptr", VolRect(bx, by, Max(fill, 1), bh), "UInt", 0xFF4F86FF, "UInt", 0xFF9CC2FF, "Int", 0, "Int", 0, "Ptr*", &fb := 0)
        fp := VolRoundPath(bx, by, Max(fill, bh), bh, bh / 2)
        DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", fb, "Ptr", fp)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", fb), DllCall("gdiplus\GdipDeletePath", "Ptr", fp)
    }
    kr := 9 * s, kx := bx + fill - kr, ky := by + bh / 2 - kr
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0x40000000, "Ptr*", &kb := 0)
    DllCall("gdiplus\GdipFillEllipse", "Ptr", g, "Ptr", kb, "Float", kx - 1 * s, "Float", ky + 1.5 * s, "Float", 2 * kr + 2 * s, "Float", 2 * kr + 2 * s)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", kb)
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", muted ? 0xFF8A93A8 : 0xFFFFFFFF, "Ptr*", &kb := 0)
    DllCall("gdiplus\GdipFillEllipse", "Ptr", g, "Ptr", kb, "Float", kx, "Float", ky, "Float", 2 * kr, "Float", 2 * kr)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", kb)

    ; The number (or "Muted"), right of the bar, with room to spare so it is never cut off.
    VolText(g, String(level), "Segoe UI", 26 * s, true, 0xFFFFFFFF, bx + bw + 14 * s, y0, w - (bx - x0) - bw - 14 * s - 30 * s, h, 2)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
}

; Puts the drawn picture on screen at the current fade level.
VolPresent() {
    pt := Buffer(8), NumPut("Int", (A_ScreenWidth - VolW) // 2, "Int", Round(A_ScreenHeight * 0.05) - VolPad, pt)
    sz := Buffer(8), NumPut("Int", VolW, "Int", VolH, sz)
    src := Buffer(8, 0)
    blend := (VolAlpha << 16) | (1 << 24)                                  ; AC_SRC_OVER, constant alpha, AC_SRC_ALPHA
    DllCall("UpdateLayeredWindow", "Ptr", VolGui.Hwnd, "Ptr", 0, "Ptr", pt, "Ptr", sz, "Ptr", VolDC, "Ptr", src, "UInt", 0, "UInt*", blend, "UInt", 2)
}

; Fades the pop-up in (dir +1) or out (dir -1, then hides it), a few steps every 15 ms.
FadeVolume(dir) {
    global VolAlpha
    VolAlpha := Max(0, Min(255, VolAlpha + dir * 51))
    try VolPresent()
    if (dir > 0 && VolAlpha >= 255) || (dir < 0 && VolAlpha <= 0) {
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

; ---------- standby: only a real button press brings the TV back ----------
; The helper asks Windows for the last input, and Windows also counts the empty reports the remote's receiver
; sends now and then while the remote sleeps. So the helper leaves the decision to this script: physical key
; presses (A_TimeIdleKeyboard ignores input made by programs), clicks, and pointer movement of more than 40 px.
; The pointer waits in the middle of the screen during standby, so movement in any direction shows.
global InStandby := false, StandbyFrom := 0, StandbyX := 0, StandbyY := 0
WatchStandby() {
    global InStandby, StandbyFrom, StandbyX, StandbyY
    if !InStandby {
        r := HelperCall("GET", "/standby/watch")
        if !RegExMatch(r, '"standby"\s*:\s*true')
            return
        InStandby := true, StandbyFrom := A_TickCount
        StandbyX := A_ScreenWidth // 2, StandbyY := A_ScreenHeight // 2
        DllCall("SetCursorPos", "Int", StandbyX, "Int", StandbyY)
        SetTimer(WatchStandby, 100)                 ; quick while in standby
        return
    }
    since := A_TickCount - StandbyFrom
    if (since < 1500)                               ; the press that started it
        return
    why := ""
    if (A_TimeIdleKeyboard < since - 1500)
        why := "button " A_PriorKey
    else if (A_TimeIdleMouse < since - 1500) {
        CoordMode("Mouse", "Screen")
        MouseGetPos(&x, &y)
        if (Abs(x - StandbyX) > 40 || Abs(y - StandbyY) > 40)
            why := "pointer moved"
        else if (GetKeyState("LButton", "P") || GetKeyState("RButton", "P"))
            why := "click"
    }
    if (why = "") {
        static polled := 0
        if (A_TickCount - polled > 1000) {           ; still in standby? (it can also end another way)
            polled := A_TickCount
            if !RegExMatch(HelperCall("GET", "/standby/watch"), '"standby"\s*:\s*true')
                EndStandbyWatch()
        }
        return
    }
    HelperCall("POST", "/standby/wake", '{"reason":' JsonStr(why) '}')
    EndStandbyWatch()
}
EndStandbyWatch() {
    global InStandby
    InStandby := false
    if PointerHidden
        DllCall("SetCursorPos", "Int", ParkX, "Int", ParkY)
    SetTimer(WatchStandby, 1000)
}
StandbyClick(*) {
    if (InStandby && A_TickCount - StandbyFrom > 1500) {
        HelperCall("POST", "/standby/wake", '{"reason":"click"}')
        EndStandbyWatch()
    }
}
; The remote's power key: standby, or back from standby when pressed again.
StandbyKey(*) {
    if InStandby
        return                                      ; WatchStandby sees the press and ends standby
    HelperCall("POST", "/power/standby", "", true)
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
; The remote's power / sleep button: standby (screen off, muted; any button brings it back). Real Sleep is not
; used: the remote cannot wake this PC from it.
for k in JsonArray(km, "global", "standby")
    try Hotkey("$" k, StandbyKey)
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

InstallKeybdHook()                      ; needed for A_TimeIdleKeyboard (physical presses only)
InstallMouseHook()                      ; and A_TimeIdleMouse
Hotkey("~*LButton", StandbyClick)
Hotkey("~*RButton", StandbyClick)
SetTimer(WatchStandby, 1000)

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
