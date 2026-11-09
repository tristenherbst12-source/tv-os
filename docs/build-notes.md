# Build Notes

Findings made while building, which later stages depend on. Newest first.

## Stage 4 (Race Calendar), tested on the dev PC on 9 November 2026

### How it works
- `launcher/js/races.js` builds one time-sorted list of sessions from two sources:
  - **F1:** `https://api.jolpi.ca/ergast/f1/<year>.json` for this year and next (next is empty until published).
    The API allows cross-origin requests (`Access-Control-Allow-Origin: *`), so the page calls it directly; no
    helper needed. Sessions: Practice 1–3, Sprint Qualifying (or the older Sprint Shootout), Sprint, Qualifying,
    Race. A session without a time shows "Time TBC".
  - **WEC:** `config/wec-schedule.json`, hand-maintained. Each session has `start` (UTC) or only `date` while the
    time is unannounced. `icalUrl` is reserved for an iCal feed later.
- **Offline:** the F1 download is saved in localStorage and through the helper in
  `%LOCALAPPDATA%\TVLauncher\cache\f1-calendar.json` (new `GET/POST /cache/{name}`). The page shows the saved copy
  at once and downloads again when it is over 6 hours old. The pill says "Updated 20:03", "Offline: Saved …"
  or "F1: No Internet" (no saved copy yet; WEC still shows).
- Times are in the PC's own time zone, named in the subtitle ("All Times in SAST" on this PC).
- "Live Now" uses an estimated length: 60 min practice/qualifying, 45 min sprint events, 2 h F1 race, and the
  hours in a WEC race's name (6/8/24; Qatar 1812km = 10 h).
- Keys: Up/Down scroll the sessions, Left/Right switch All / F1 / WEC (remembered), Back goes home.

### WEC data
- The 2026 WEC season ended with Bahrain on 7 November 2026, so the file holds the **2027** calendar from the FIA
  announcement of 12 June 2026: 9 rounds, race-day dates only. Add practice/qualifying and real start times
  from each event's timetable on fiawec.com when they are published (usually a few weeks before each event).

### What was tested (preview browser at 1920×1080, then with the helper running in test mode)
- 24 upcoming sessions (Las Vegas, Qatar and Abu Dhabi F1 plus 9 WEC races); countdown ticks every second.
- Filter All / F1 / WEC; scrolling to the end and back; the focused row stays clear of the faded edges.
- A pretend live WEC race (injected) shows "Live Now" with the time left.
- No internet with a saved copy → "Offline: Saved"; no internet and no copy → WEC only, "F1: No Internet".
- With the helper: config and the F1 copy come from the helper; with localStorage cleared and no internet the
  helper's copy fills the page.
- Home tile → Race Calendar → Back returns with the Race Calendar tile focused. Lite mode drops the blur.
- Rows used `mouseenter` at first; scrolling moved rows under a resting pointer and stole the focus, so rows use
  `mousemove` (matters for the air mouse).

### "Next Session" chip on the home screen (approved by the owner)
- A pill in the top-left corner of the home screen (the greeting is centred, so the right side had no room):
  series badge, event ("Grand Prix" shortened to "GP"), session, and when: "Fri 20 Nov 02:30", then the
  weekday within a week, "Tomorrow 02:30", "In 3h 20m" under 6 hours, "In 40 Min", "Live Now".
- Same data and offline copy as the Race Calendar page; hidden when there is nothing upcoming. Not focusable;
  the Race Calendar tile opens the page.
- Tested with the real calendar and with a made-up session 40 minutes ahead and 20 minutes in.

### For the TV PC
- When the helper is down, Windows takes about 2 s to refuse each localhost connection, so pages load slower in
  that state only.

## Stage 3 (Settings and Power), tested on the dev PC on 9 November 2026

### Test mode
`start.ps1 -Windowed` (or `-TestMode` on its own) starts the helper with `-TestMode`. Sleep, Restart, Shut Down, the
sleep timer and screen-off are then only written to `logs\helper.log`, and the pages show "Test Mode". On the TV PC
start it without these switches.

### What was tested (preview browser plus the full system, test mode)
- **Volume:** Left/Right in steps of 5, OK mutes; changing the volume unmutes, like a TV. It uses the real Windows
  volume (Core Audio); restored afterwards.
- **Sound output:** lists active playback devices; OK makes one the default for all roles (via the undocumented but
  long-stable `IPolicyConfig` interface that audio-switcher tools use). Switched away from and back to the default
  device.
- **Sleep timer:** Off / 30 / 60 / 90 min, Sleep or Shut Down. Stored in `%LOCALAPPDATA%\TVLauncher\sleep-timer.json`,
  so a helper restart does not lose it; cleared before it acts, so waking up does not set it off again. A 1-minute
  timer went off on time.
- **Screen off when idle:** home screen only, and only while the launcher is in front. Tested with a 3-second
  setting. On the TV the off message is `SC_MONITORPOWER`; check that the TV goes to standby and that the remote
  wakes it.
- **Wallpaper, Lite mode:** saved through the helper and applied straight away.
- **Wi-Fi and Bluetooth:** status in the row, and OK opens the Windows Settings page. Home closes Windows Settings
  (`winsettings` hidden entry in apps.json).
- **Desktop PIN:** 4 digits, stored salted and SHA-256 hashed in settings.json, and cannot be changed through
  `POST /settings`. Set, wrong PIN, right PIN and remove all tested. A remote's number keys or the on-screen keypad
  both work.
- **Power page:** Sleep / Restart / Shut Down, with Cancel focused first in the confirmation.
- Coming back from Settings or Power puts focus on the tile you came from.
- `scripts/test-apps.ps1`: all 7 apps still pass.

### For the TV PC
- `GET /status` takes about 3 s (netsh plus the network adapters), so the Settings page fills those rows in after
  it opens.
- Bluetooth status only says whether there is a radio. The dev PC has none, so "pair" could not be tested here.
- Sleep uses `SetSuspendState`. If hibernation is on, Windows may use hybrid sleep; `setup.ps1` could turn
  hibernation off (`powercfg /h off`).

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
