# Build Notes

Findings made while building, which later stages depend on. Newest first.

## Stage 2 (helper and launching), tested on the dev PC on 9 November 2026

### How the pieces fit
- `scripts/start.vbs` → `scripts/start.ps1` (supervisor) → `helper/helper.ps1 -ManageLauncher` + `hotkeys/tv.ahk`.
- The helper starts the launcher window and restarts it within about 5 s if it closes. To stop everything, stop the
  helper first, or it will start the launcher again.
- Machine-local state lives in `%LOCALAPPDATA%\TVLauncher`: `helper.json` (port + token), `profiles\` (one Edge
  profile per window: launcher, youtube, f1tv, browser) and `logs\`.
- The launcher page reaches the helper from `file://` with no Edge flags needed (checked on Edge 157). The
  `LocalNetworkAccess` flags in `common.ps1` are a precaution for future Edge versions.

### Store apps
- Starting them uses `IApplicationActivationManager`, not `explorer.exe shell:AppsFolder\...`. While explorer is not
  the shell, starting `explorer.exe` would bring up the whole Windows desktop.
- **Netflix's "Store app" is an Edge web app.** `pwahelper.exe` starts it, and its window belongs to the user's
  everyday Edge process, so no process path or command line identifies it. The window's AppUserModelID does:
  `4DF9E0F8.Netflix_mcm4njqhnhss8!Netflix.App`. The helper reads that ID from the window to decide what Home does.
  This works for classic Store apps too.
- Package names confirmed on this PC: `4DF9E0F8.Netflix`, `SpotifyAB.SpotifyMusic`. Prime Video and Disney+ were not
  installed here, so check their names on the TV PC.

### Edge profiles sign themselves in
On a Windows account that is a Microsoft account, every new Edge profile signs in to that account by itself. With
sync on, it also pulls in the user's extensions (Teleparty opened a sign-up tab inside the YouTube window).
`--disable-sync` (now on every window we start) stops the extensions arriving, but the profile still signs in.
**`setup.ps1` (stage 5) should set Edge policies for the TV user**
(`HKCU\Software\Policies\Microsoft\Edge`):
- `ImplicitSignInEnabled = 0`, `BrowserSignin = 0`, `SyncDisabled = 1`: no account in the TV profiles
- `HideFirstRunExperience = 1`: no welcome or sync screens on new profiles
- `BackgroundModeEnabled = 0`, `StartupBoostEnabled = 0`: closing a window really ends its profile's process, which
  the launcher watchdog relies on
- Check that the Netflix web app still works with these set.

### YouTube TV interface: blocked
`https://www.youtube.com/tv` answers every desktop browser with "You are being directed to youtube.com". Tested
with Tizen, webOS, Xbox One, PS4 Leanback and Cobalt user agents (one in a real window, the others headless). The
user agent alone no longer gets the TV interface. **Decision needed** (open item in HANDOVER section 9).

### H.264 only
`extensions/h264only` loads with `--load-extension` (Edge registered it in the YouTube profile). It is unpacked, so
Edge may show a "Turn off extensions in developer mode" bubble. Check on the TV whether it appears in the
full-screen app window.

### Not tested yet
- `hotkeys/tv.ahk`: AutoHotkey is not installed on the dev PC. It is written for v2 but has never been run.
- Kiosk mode (only `-Windowed` was tried), F1TV, Spotify, and the Home and Back buttons on the real remote.
