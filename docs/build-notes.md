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

### YouTube TV interface: blocked, and we stop here
`https://www.youtube.com/tv` answers every desktop browser with "You are being directed to youtube.com". Tested
with Tizen, webOS, Xbox One, PS4 Leanback and Cobalt user agents (one in a real window, the others headless).
Follow-up investigation (9 November):
- YouTube's server decides. To a TV user agent with plain headers it sends the full TV app (~200 KB); to a desktop
  browser it sends a 5.7 KB page whose inline script redirects to `youtube.com/?app=desktop`.
- Changing the user agent, User-Agent Client Hints, `navigator.platform` and `navigator.userAgentData` did not
  change the answer.
- Google sites also receive browser-validation headers from Edge (`x-browser-validation` and others) that let
  Google check that the browser is what it claims to be.
- Going further would mean defeating Google's browser-genuineness and bot checks. We are not doing that: it is
  against YouTube's terms and would break whenever Google changes the check.
- **Decision:** the tile opens the normal `https://www.youtube.com/` in its own full-screen Edge window at 150%
  (`"scale": 1.5` in apps.json → `--force-device-scale-factor`), with no fake user agent. The zoom applies only to
  that window's own Edge process; the user's everyday Edge is unaffected (checked on the dev PC). The air-mouse
  pointer drives it. Sign in to YouTube once in that window; the profile keeps the login.

### H.264 only
`extensions/h264only` loads with `--load-extension` (Edge registered it in the YouTube profile). It is unpacked, so
Edge may show a "Turn off extensions in developer mode" bubble. Check on the TV whether it appears in the
full-screen app window.

### Tested on the dev PC (AutoHotkey 2.0.31)
`scripts/test-apps.ps1` opens every app tile through the helper, sends the Home key the way a remote would, and
checks the result. All 7 pass: Netflix, Prime Video and Disney+ close; Spotify minimises; F1TV, Browser and YouTube
close; the launcher is back in front each time. On a web app's very first launch, Edge shows an "App installed"
pop-up in front of it, which Home only minimises; from the second launch it is fine.
- Prime Video (`AmazonVideo.PrimeVideo`, app ID `PWA`) and Disney+ (`Disney.37853FC22B2CE`, app ID `App`) are Edge
  web apps too. Spotify's Store package includes the real `Spotify.exe`, so it is found by install folder.
- Back: a tap goes to the app; holding it for 0.8 s goes Home. This works repeatedly (the first version used
  `KeyWait` and never detected the hold).
- tv.ahk sends key presses to the helper while the launcher is in front (for the key-test page).

### Not tested yet
- Kiosk mode (only `-Windowed` was tried), the escape hatch hotkey (it starts `explorer.exe`, which is already
  running on the dev PC), and the Home and Back buttons on a real remote.
