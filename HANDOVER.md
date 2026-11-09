# TV Launcher — Handover for Claude Code

Custom "smart TV" home screen for a mini PC driving a non-smart TV. Design is **approved**; this document captures every decision so far. Build it in stages and **show a checkpoint after each stage** before moving on (owner's standing preference).

---

## 1. Context

- **Owner:** Tristen ("Tris"), shared with his girlfriend Jazz. Greeting uses "Jazz & Tris".
- **TV:** 42" Full HD (1080p), non-smart.
- **PC:** Lenovo ThinkCentre M73 Tiny (machine type 10AX, model S07Q0J). Intel Core i3 4th gen (Haswell, HD Graphics 4400), ~8 GB RAM, 320 GB 2.5" HDD (will be swapped to a SATA SSD once everything works, then reinstalled from scratch).
- **Outputs:** DisplayPort 1.2 + VGA, no HDMI. Use a **DP → HDMI cable** (carries audio). Never VGA.
- **OS:** Windows 10 Pro (kept on purpose, see 2.1). Must be enrolled in the free consumer ESU program (security updates until 12 Oct 2027).
- **Remote:** generic 2.4 GHz air-mouse remote (gyro pointer, arrows, OK, Back, Home, volume, mic). Exact model not final. **Do not assume key codes.** Build a key-capture test page (see 6.6).
- **Time zone:** Africa/Johannesburg.

## 2. Key decisions (already made, don't revisit without asking)

### 2.1 Windows-based shell, not Linux
Required apps: **YouTube, Netflix, Prime Video, Disney+, F1TV, Spotify, a standard browser.** On Linux, DRM caps Netflix/Disney+/Prime in the browser at roughly 720p or lower. The TV is 1080p, so we chose a stripped-down Windows 10 with a custom launcher replacing the desktop.

### 2.2 How apps open
| Tile | Launch method |
|---|---|
| Netflix | Microsoft Store app (via AUMID) |
| Prime Video | Microsoft Store app |
| Disney+ | Microsoft Store app |
| Spotify | Desktop/Store app |
| YouTube | TV-style 10-foot UI (youtube.com/tv) in a dedicated Edge kiosk window. **Verify** it works. youtube.com/tv usually needs a TV user-agent. Force **H.264** playback where possible, because Haswell has no VP9 hardware decode. |
| F1TV | Edge, full screen, own profile so the login sticks |
| Browser | Normal Edge window (with a remote-friendly way back home) |

The owner installs the Store apps and signs in manually. That can't be scripted.

### 2.3 Icons
**Do not hand-draw or recreate any brand logos.** Use each app's own icon file from the PC:
- Store apps: read the package manifest (`Get-AppxPackage` → `AppxManifest.xml` → `Square150x150Logo` / `Square44x44Logo`, then pick the best scale/target-size asset) and copy it into the launcher's `icons/` folder.
- Web tiles (YouTube, F1TV): fetch the site's own `apple-touch-icon` / manifest icon on the PC at setup time.
- Fallback: the current coloured placeholder glyph if no icon is found.

## 3. Approved design

**Source of truth:** `design/index-blue.html` (open it in Chrome or Edge and press F11; arrows/Enter work). `design/glass-blue.png` is the approved screenshot. `design/index-sage.html` is a kept alternative palette (sage/olive), selectable from Settings.

Keep the visuals exactly as approved:
- **Wallpaper:** 4 large blurred, slowly drifting colour blobs plus a vignette. Palette changes by time of day (morning 05–11, day 11–17, evening 17–21, night 21–05), with a 4 s crossfade. Blue is the default theme; sage is the alternative.
- **Header (centred):** greeting `Good Morning / Good Afternoon / Good Evening, Jazz & Tris` (Inter 600). Clock in **Inter, weight 800**, tight tracking, tabular numbers, with a **glass effect**: a semi-transparent white gradient fill clipped to the text, a 1 px white rim via `drop-shadow`, and a soft dark drop shadow. **Do not use `-webkit-text-stroke`**: Inter's variable contours overlap and the stroke shows lines inside the "1". Date (`Monday 9 November`) in **pure white**. Status pills (Day/Night mode, Online) are absolutely positioned top-right.
- **"Watch and Listen" (centred label):** 6 large glass tiles (YouTube, Netflix, Prime Video, Disney+, F1TV, Spotify). Each tile has the app icon top-left, name plus subtitle bottom-left, and an accent glow in the app's colour. The focused tile scales up 1.08, lifts, gets a brighter border and an accent glow.
- **"More" (centred, smaller, dimmer label):** 4 compact tiles (Browser, Race Calendar, Settings, Power) at about 72% width, centred. Labels are dim until focused.
- **Hint bar:** Move / Open / Home / Lite Mode.
- **Font:** Inter (OFL), embedded locally. **No internet font dependency.** SF Pro was ruled out on licensing grounds.
- **All home-screen text in AP title case** (e.g. "Watch and Listen", "Series and Films", "Live and Replays", "Race Calendar", "Lite Mode").
- **Lite mode** turns off backdrop blur and the blob animation (Haswell iGPU fallback). It must be available as a Setting and stay saved.

Known design note: once the real icons are in, consider softening each tile's accent glow so the blue background stays dominant.

## 4. Architecture

```
Boot → auto-login → custom shell (not explorer.exe)
        └─ start.ps1 / start.cmd
             ├─ helper   (local service on 127.0.0.1:<port>, launches apps and runs system actions)
             ├─ hotkeys  (AutoHotkey v2: Home/Back → return to launcher; escape-hatch combo)
             └─ launcher (Edge --kiosk file:///.../launcher/index.html, own user-data-dir)
```

- **Launcher:** the approved HTML/CSS/JS, extended. Talks to the helper with `fetch('http://127.0.0.1:<port>/...')`. Protect it with a random token written at install time (the helper rejects requests without it) and bind to loopback only.
- **Helper:** pick the simplest robust option, either a PowerShell `HttpListener` script or a small compiled binary. Endpoints, roughly: `POST /launch/{appId}`, `POST /home`, `GET/POST /volume`, `POST /mute`, `GET/POST /audio-output`, `POST /sleep-timer`, `POST /power/{sleep|restart|shutdown}`, `GET /status` (wifi, bluetooth, storage, uptime), `POST /restart-launcher`, `POST /desktop` (escape hatch, PIN-checked).
- **Return home:** the remote's Home (and Back when an app has no back stack) closes or minimises the foreground app and brings the launcher window to the front. Decide close vs minimise per app (streaming apps: close is cleaner; Spotify: minimise so music keeps playing).
- **Escape hatch:** a hidden key combo (e.g. Ctrl+Alt+Shift+D) or the Settings → Windows Desktop option starts `explorer.exe`, with an optional PIN.

## 5. Setup script (`setup.ps1`, run as admin, idempotent)

Must be safe to run again on a fresh install (the SSD migration is planned). Steps:
1. Check Windows edition/version; remind the owner about ESU enrolment.
2. Debloat: remove preinstalled junk apps (keep Store, Edge, the required apps), turn off tips, suggestions, ads, Cortana/search highlights, lock-screen spotlight, notification toasts, and background apps.
3. Windows Update active hours set so it **never restarts during the evening**.
4. Power plan: high performance, never sleep while the launcher is idle (screen-off is handled by our own Setting), USB selective suspend off (keeps the remote dongle awake).
5. Auto-login for the TV user account (Sysinternals Autologon or Winlogon registry; store the password safely).
6. Replace the shell for that user only (HKCU `...\Winlogon\Shell` → `start.cmd`). Note: Shell Launcher is Enterprise/Education only, so on Pro use the per-user registry approach.
7. Install dependencies (winget where possible): AutoHotkey v2, plus Spotify if not from the Store.
8. Extract app icons (2.3) and resolve AUMIDs for installed Store apps into `config/apps.json`.
9. Create Edge profiles/user-data-dirs for the launcher, YouTube TV and F1TV.
10. Provide **`uninstall.ps1`** to restore explorer.exe as the shell and turn off auto-login.

## 6. Features to build

### 6.1 Home screen
As approved (section 3), wired to the real launches.

### 6.2 Race Calendar (F1 + WEC)
- **F1:** Jolpica API (free, no key; Ergast-compatible, `https://api.jolpi.ca/ergast/f1/<season>.json`). Show all sessions (FP1–3 / Sprint / Qualifying / Race) in **local time (SAST)**. Cache it locally so the screen works offline.
- **WEC:** no free official API, so use a hand-maintained `config/wec-schedule.json` (season, round, event, sessions with UTC times), pre-filled for the current/next season. Leave room to optionally subscribe to an iCal URL later.
- **Screen:** "Next session" hero with a live countdown, then upcoming sessions for both series, with a series filter (All / F1 / WEC). Same glass style.
- **Optional:** a small "Next Session" chip on the home screen (ask before adding).

### 6.3 Settings (all approved)
1. **Volume:** big slider plus mute, remote-friendly.
2. **Sound output:** list playback devices and switch between TV, Bluetooth headphones or a soundbar.
3. **Sleep timer:** off / 30 / 60 / 90 min → sleep or shut down. Show the remaining time.
4. **Screen off when idle:** put the display to sleep after X minutes idle on the home screen.
5. **Wallpaper:** Dark Blue / Sage / Rotate.
6. **Lite mode:** toggle (saved).
7. **Wi-Fi and Bluetooth:** status plus shortcuts to the Windows pairing pages.
8. **Restart launcher.**
9. **Windows desktop:** escape hatch with optional PIN.
10. **System info:** free storage, uptime, launcher version.

### 6.4 Power tile
Sleep / Restart / Shut down, with a confirmation step.

### 6.5 Persistence
Settings live in `config/settings.json` (via the helper) so they survive reinstalls and can be backed up. Use `localStorage` only as a cache.

### 6.6 Remote key-capture page
A debug page listing every `keydown` `key`/`code` and AHK-detected key, so the real remote's buttons can be mapped once it arrives. Make the key map configurable in `config/keymap.json` (shared by the launcher and AHK).

## 7. Suggested repo layout

```
tv-launcher/
  launcher/        index.html, css/, js/, fonts/ (Inter woff2), icons/, pages/ (settings, races, power, keytest)
  helper/          helper.ps1 (or src for compiled helper)
  hotkeys/         tv.ahk
  config/          apps.json, settings.json, keymap.json, wec-schedule.json
  scripts/         setup.ps1, uninstall.ps1, start.cmd, extract-icons.ps1
  design/          index-blue.html, index-sage.html, glass-blue.png   (reference only)
  README.md        step-by-step install guide for the owner
```

## 8. Build order (checkpoint after each stage)

1. **Launcher refactor:** split the prototype into files, add an apps/config loader, real icon loading with fallback, and the keymap. *Checkpoint: runs in a normal browser.*
2. **Helper and launching:** helper service and real app launches; return-home flow via AHK. *Checkpoint: on the PC, each tile opens and Home returns.*
3. **Settings and Power pages.** *Checkpoint.*
4. **Race Calendar (F1 + WEC).** *Checkpoint.*
5. **setup.ps1 / uninstall.ps1 / README.** *Checkpoint: dry run, then a full run on the PC.*
6. **Polish on real hardware:** test performance on the Haswell iGPU (blur, animation), YouTube codec, and remote mapping.

## 9. Open items and things to verify

- youtube.com/tv in Edge: whether it needs a user-agent override, and how to force H.264 there.
- The exact behaviour of each Store app on "close" vs "minimise" (some resist closing).
- The final remote model and its key codes (use the key-capture page).
- The WEC schedule for the next season (pre-fill once it's announced).
- Whether to add the home-screen "Next Session" chip.
