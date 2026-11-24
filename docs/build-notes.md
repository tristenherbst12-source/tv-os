# Build Notes

Findings made while building, which later stages depend on. Newest first.

## Stage 6, round 1: fixes after the first install on the mini PC (11 November 2026)

### What the owner found, and the fix
1. **Setup never asked for the password**, so auto-login failed ("invalid password"). `Get-LocalUser`'s
   `PasswordRequired` is often False even for accounts with a password. Setup now always asks (Enter = no
   password / keep the stored one), checks it, and only switches auto-login on once a password is known good.
2. **Pointer visible**: tv.ahk hides the system pointer on any key press or after 3 s still, parks it in the
   bottom-right corner (no hover previews), and puts it back where it was when the touchpad is touched. Only
   without `-Windowed`. Launcher pages also hide it with CSS (`body.pointer-idle`).
3. **Remote Home opened Edge's own home page in the launcher window**: Home was only caught while another app was
   in front, so Edge acted on `Browser_Home` itself. Now always caught; on the launcher it becomes F24 (keymap
   `home`). Safety net: the helper reloads the launcher if its window title is not one of our pages for 10 s.
4. / 9. **DStv and Twitch** tiles (`dstv.stream`, `twitch.tv`). The Watch row has 8 tiles, shows 6 and slides with
   the focus (`.row-view` / `.row.slide`). DStv's site only has a plain cyan favicon, so the tile uses its glyph.
5. / 10. / 11. **Apps are now our own full-screen TV windows** (owner agreed): Netflix, Prime Video, Disney+ and
   Spotify open their websites (`edge-app`); their Store apps were Edge PWAs, so quality is the same. No title
   bars (`--app --start-fullscreen`, checked: still full screen after a video leaves full screen). Spotify web
   minimises on Home; opening the tile again brings the same window back (no second window).
   **`extensions/tvnav`** (loaded into every TV window) does remote navigation: arrows move a highlight to the
   nearest clickable thing (same column/row preferred, cards deduplicated by link), OK presses it with a full
   pointer-event sequence, Backspace = back (leave full screen, else history back; not in text boxes). While
   watching: Left/Right seek 10 s, OK = full screen then pause/play. Tested with the DevTools protocol on YouTube
   (results, watch page, seek, full screen, back), Twitch and Spotify (signed out).
   **Edge now disables `--load-extension` extensions from a profile's second start** (disable reason 16777216).
   `--disable-features=DisableLoadExtensionCommandLineSwitch` keeps them working (checked over several restarts).
   This probably also stopped h264only on the mini PC. If a future Edge drops that switch, the extensions need
   another way in (packed + policy).
6. **"Test Mode" always showed**: `.pill{display:flex}` beat the `hidden` attribute. Global
   `[hidden]{display:none!important}`.
7. **Wrong desktop PIN**: not reproduced. Chromium sends fake mouse events when the page changes under a resting
   pointer; with the touchpad pointer over the PIN pad that moved the highlight. All hover handlers now use
   `TV.onHover` (only real pointer movement counts). Rejected PINs log how many digits arrived.
8. **Network speed test**: Settings > Connections. Cloudflare's speed endpoints (CORS `*`): ping, 8 s download
   (4 streams), 8 s upload. Dev PC: 34 ms, 938 down, 269 up.

### The remote (touchpad model), tested on the dev PC
Arrows; OK = Enter; Back = **Backspace** (repeats while held); Home = `Browser_Home`; Search = `Browser_Search`
(blocked); volume and media keys left to Windows; touchpad = normal mouse. keymap.json updated.

### Tested on the dev PC (test mode)
`scripts/test-apps.ps1`: all 9 tiles open, Home closes them (Spotify minimises), launcher back in front. Spotify
reopens as "resumed" with one window. Speed test dialog incl. Back to stop. Sliding row incl. Down to the More row.
**Not confirmed:** the owner reported the remote checks (Home on the launcher, Search, PIN, YouTube, Spotify) as
working, but the helper log shows no activity for them, so treat them as still to check on the TV. Pointer hiding
(off with `-Windowed`) and signed-in Netflix/Prime/Disney+/DStv navigation also need the TV.

## Stage 5 (setup, uninstall, README), previewed on the dev PC on 9 November 2026

### Scripts
- `scripts/setup.ps1`, `scripts/uninstall.ps1`, shared code in `scripts/setup-lib.ps1`. **Preview by default:** every
  change is listed with the setting's current value (`[ok]` / `[would]` / `[check]`) and nothing is changed.
  `-Apply` needs an admin window and the typed word `SETUP` (or `-Yes`). `-TVUser` picks the account (default:
  the one running it); `-Skip a,b` leaves steps out.
- The TV user's own registry is written through `HKEY_USERS\<SID>`, or their `NTUSER.DAT` is loaded when they are
  not signed in, so setup also works from a separate admin account.
- **Shell:** `HKCU\...\Winlogon\Shell = wscript.exe "<install>\scripts\start.vbs"` for the TV user only.
- **Auto-login:** local accounts only. The password is checked against Windows first, then stored as the LSA
  secret `DefaultPassword` (what Sysinternals Autologon does), never as plain text in the registry.
  `DevicePasswordLessBuildVersion = 0` so Windows Hello does not block it. A Microsoft account gets a `[check]`
  pointing to the README (use a local account `TV`).
- **Windows Update:** policy active hours 08:00–02:00 (the 18-hour maximum) and `NoAutoRebootWithLoggedOnUsers`.
- **Power:** High performance (re-added if Windows hid it), no sleep/hibernate/screen/disk timeouts, USB selective
  suspend off, no password on wake (`CONSOLELOCK 0`), hibernation off.
- **Debloat:** exact package names only (plus `king.com.*`); the TV apps, Store, Edge, App Installer, frameworks,
  Calculator and Photos are never on the list. Also turns off tips/ads/suggestions, search highlights, toasts and
  background apps. With a custom shell, `Run` keys (OneDrive, etc.) do not start at all: explorer runs those.
- **Edge policies** for the TV user: the six from stage 2 plus no default-browser nag, recommendations,
  promotional tabs or sidebar.
- **Uninstall** removes the shell value, auto-login and stored password, and our Edge policies; stops the
  launcher (start.ps1 first, then the helper, so nothing restarts). `-RemoveData` also deletes
  `%LOCALAPPDATA%\TVLauncher`. Debloat, power and update settings are left (listed in the script header).
- `scripts/extract-icons.ps1` (setup step 10, also usable alone): Store apps use the largest `Square44x44Logo`
  (tight icon, prefers `altform-unplated`), falling back to `Square150x150Logo`; websites use their own manifest or
  `<link rel=icon>` icons, skipping `monochrome` ones and preferring non-maskable; the Browser tile uses Edge's
  `VisualElements\Logo.png`, cropped to the visible logo. Icons are `.gitignore`d (extracted on each machine).
- Settings > System > **Remote Button Test** opens the key-test page (there was no way to reach it with the remote).

### Tested on the dev PC
- Previews of setup (71 changes listed) and uninstall; nothing changed. `-Apply` without admin refuses; unknown
  user gives a clear message.
- **Bug found:** the shared file's `$Script:Apply` overwrote the `-Apply` switch (same scope after dot-sourcing),
  so `-Apply` silently ran as a preview. Renamed to `$Script:ApplyChanges`; now refuses without admin as intended.
- Apply-mode helpers (set, already-right, remove, one change per loop item) tested on a scratch HKCU key, then
  deleted.
- extract-icons ran for real: all 7 icons copied; the home screen shows them.

### Not tested (needs the TV PC, as admin)
- A real `-Apply`: the LSA password, loading another user's hive, app removal, powercfg, winget install of
  AutoHotkey, and the custom shell actually starting at sign-in. Run the preview first, then `-Apply`, on the TV PC.

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

## Stage 6, round 2 (11 Nov 2026): new SSD install

### Endless restart in kiosk mode
In kiosk mode Edge titles the launcher window `Home - [InPrivate] - Microsoft Edge`, not `Home`. The round 1
"left the TV pages" check did not recognise that and reloaded the home screen every 10 s, forever. The check now
accepts the suffix, allows at most 3 reloads in 10 minutes, and the escape hatch stops supervising.

### Speed on the HD 4400
Measured at 1080p with the GPU switched off (software drawing makes the cost visible): 8 fps before, about
40 after. The cost was a live `blur(90px)` on the four drifting wallpaper blobs and `backdrop-filter` on every
tile, pill and settings row, all redone every frame. Blobs are now radial gradients (palette crossfade kept
with `@property`), the glass has no backdrop blur, the focus glow fades in on `::after` instead of animating a
big `box-shadow`, and full-screen blurs (launch overlay, dialogs) pause the wallpaper. The sliding Watch row is
no longer clipped (that cut the glow off); tiles outside the 6 shown fade out.

### Volume buttons
Windows turns the volume keys into volume changes in Explorer, which does not run on the TV, so they did nothing.
tv.ahk now handles them (2 % steps, mute) and shows a small volume bar (TV only, not with `-Windowed`).

### Remote navigation no longer an Edge extension
Edge 157.0.4341.46 switches `--load-extension` extensions off from a profile's second start again; the
`DisableLoadExtensionCommandLineSwitch` workaround from round 1 stopped working. Each TV window now opens with
`--remote-debugging-port` (a free port, 127.0.0.1 only) and `helper/tvnav-host.ps1` attaches to it, adds
`inject/tvnav.js` (and `inject/h264only.js` for YouTube) to every page, and turns OK into a real click inside the
page (`Input.dispatchMouseEvent`; the real pointer does not move). Prime Video's cards and profile menu only
respond to real clicks. Gotcha: text read with `Get-Content` carries file details that `ConvertTo-Json` then
serialises too (very slowly), so the scripts are read with `[IO.File]::ReadAllText`.

### Navigation rules (inject/tvnav.js), tested signed out on Prime Video, YouTube, Twitch, Spotify, Netflix,
Disney+, DStv and F1TV
- Up/Down go to the next row and keep the column (remembered from the last Left/Right); straight below first,
  then the nearest thing counting sideways distance at half.
- From a card, its caption (title, channel, tags) and small links between rows ("See more") are stepped over.
- Left/Right stay level with the current item; at the end of a row nothing happens. Past the last visible card a
  carousel's hidden cards are reached, pressing the carousel's own arrow to bring them into view.
- Duplicate links are merged only when touching (merging the same film in neighbouring rows skipped rows).
- Skipped: empty see-through boxes, things covered by something else (but not by their own label, Netflix's
  sign-in), containers holding several buttons, screen-wide banners.
- Tiles whose title is the only link (Spotify) are one stop.
- An open pop-up (dialog / aria-modal) keeps the highlight inside it; after OK opens a menu, its new items come
  first, and Up past the first one returns to the button.
- "Watching" (Left/Right skip, OK full screen) only for a video you started (OK or Play shortly before it began,
  remembered across the page change) or one that is full screen: self-starting trailers no longer take over the
  arrows. Live streams are not skipped through.

Not covered: cookie pop-ups inside a cross-site frame (F1TV's) need the touchpad once. Signed-in pages (profile
pickers, Netflix rows, Disney+ rows, DStv channels) could not be tried here.

### Watching videos like a TV (11 Nov 2026, later)
- Opening a video with OK goes straight to full screen. The companion presses the player's own full-screen key
  (F, a real key press via `Input.dispatchKeyEvent`) so YouTube switches to its own full-screen layout; requesting
  full screen on the page instead left YouTube's normal page (side list of videos) on a full-screen window. If F
  does nothing, the site's full-screen button is clicked as a user action (`Runtime.evaluate` with `userGesture`).
- In full screen the stops are the player's controls plus any open menu; Up/Down show the controls (a real
  pointer move inside the page; players ignore made-up ones) with the highlight on the bottom row, leftmost first.
  The page's pointer is kept on the highlighted control so the controls and menus stay open.
- When OK replaces the highlighted item (a sub-menu), the highlight moves to the nearest new item; in full screen
  only into menu items, otherwise back to watching (after choosing a quality).
- OK clicks where an item is really on top (the bottom of YouTube's settings menu lies over the progress bar's hover
  area, so its middle would have clicked the progress bar).
- `inject/youtube.js` sets 1080p (or the best below it) once per video through the player's own API; a quality you
  choose yourself stays.
- Back in full screen: first hides the controls, then leaves full screen and goes back a page.
- Not working yet: Twitch's settings menu (Twitch hides its control layer, menu included, right after a click).

## Stage 6, round 3 (11 Nov 2026, night): first mini PC test of the apps

Feedback from the mini PC, and what changed (tested on the dev PC; DStv and Spotify signed in):

- **YouTube full screen:** selecting the bottom controls scrolled the player box, which YouTube treats as "open
  the More videos grid" (video squeezed to the top, stuck there). The highlight no longer scrolls anything in full
  screen, and Back / hiding the controls / seeking put a scrolled player back (`unscrollPlayer`).
- **Netflix:** the card under the (hidden) pointer popped up its preview, which covered its neighbours (so arrows
  skipped a film) and trapped the highlight (it is a `role=dialog`). On Netflix every arrow press now moves the
  page's pointer off the page (`parkPointer`), and hover previews are never treated as pop-ups. In Netflix's player
  Left/Right and OK go to Netflix itself (it seeks 10 s and pauses on its own, and refuses outside seeking).
  Not testable here without a Netflix sign-in.
- **DStv:** profiles, channels and cards are plain boxes with a click handler (no links or buttons), so only "Add
  Profile" was reachable: the "stuck on the right" bug. New rule: the outermost box with a hand pointer and no
  visible link/button inside is a stop (`pointerBoxes`). In the player, the controls open on the main bar (the
  lowest row with 3+ buttons), not on the lone "Channel Lineup" button under it. Up no longer jumps to the menu bar
  pinned at the top while there are rows above.
- **Trailers:** OK on a logo of a page with a trailer counted as "you started a video" and sent the trailer full
  screen. OK now counts only if it opened another page or was on something like Play / Watch / an episode.
- **Spotify:** scale 125% -> 150%. Library rows (see-through click areas over the row, `clickLayer`) and song rows
  (one stop each, OK plays: `ROW_STOPS`) work; things half hidden under the player bar are no longer "covered".
- **Spotify on the home screen:** `inject/spotify.js` reads Spotify's media-session info; tvnav-host.ps1 writes it to
  `%LOCALAPPDATA%\TVLauncher\now-playing.json`; the helper serves it at `GET /now-playing` (only while the file is
  fresh: the page reports every 10 s); the home screen shows a chip (cover, song, artist; bars move while playing).
- **Pop-up safety net:** when the highlight is held in a pop-up and a direction has nowhere to go twice in a row, it
  lets go of that pop-up. Moves that find nothing are written to `tvnav-host.log` (`tvnavLog`) for diagnosis.
- **Wi-Fi / Bluetooth settings:** "could not open" on the TV. Settings is now tried by its link, then started
  directly, then brought in front of the TV window; Bluetooth falls back to Windows' "Add a device" window. The
  real error is written to `helper.log`. Not tested on the TV yet (needs the PC without the Windows desktop).

### Turning the PC on with the remote
The remote's USB receiver can wake the PC from Sleep, but from Shut Down only if the BIOS has a "wake from USB /
keyboard in S5" option (to check on the M73: Power menu). Sleep draws about 1-2 W, similar to the TV's standby.

## Stage 6, round 4 (12 Nov 2026)

- **Netflix (from a video of the TV):** Left on a row's first film paged the row backwards, and Netflix rows wrap
  round, so it jumped to the row's end; the highlight also landed on half-hidden "peek" cards and the row arrows.
  On Netflix the row arrows are no longer stops, peeking cards are stops only to page a row on (Right) or back to
  where it started (Left; pages are counted per row), and Up/Down only land on fully visible cards. Not testable
  here: the Netflix Store app is an Edge web app in the everyday Edge profile, Edge refuses a debugging port on
  the default profile, and its cookies use app-bound encryption, so a copied profile is signed out.
- **Waking from Sleep with the remote:** Windows lets only "armed" devices wake the PC. Setup step 5 now arms every
  keyboard, mouse, consumer-control and system-controller device (`powercfg /deviceenablewake`), which covers the
  remote's arrows, touchpad and media/power buttons. If it still does not wake, the BIOS is next (Enhanced Power
  Saving Mode cuts USB power in sleep on some ThinkCentres).
- **Screensaver** (`launcher/js/screensaver.js`): Home on the home screen, or `screensaverMinutes` (default 5,
  Settings > Screensaver) untouched there. home.js only counts idle time while the home screen has focus, so it
  never starts over an app. Photos: Wikimedia Commons featured pictures of mountains, lakes, waterfalls, beaches,
  forests, sunsets and landscapes (wide ones only, about 300), fetched by the page (Commons allows `origin=*`) at
  most once a day and kept in localStorage; credited on screen. Time, date and the Spotify song (helper
  `/now-playing`). Any key ends it and is swallowed; real pointer movement too.

### Netflix, tested signed in (12 Nov 2026)
Netflix's new layout (cards are `a[href="/browse?jbv=<id>"]` in `section.carousel-row`, unlabelled edge arrows):
- **Every other film was skipped**: links were grouped by address without the query, so neighbouring films (all
  `/browse?...`) were merged as "one card". `linkKey` now keeps the query (minus tracking and playlist extras).
- The unlabelled edge arrow is not a stop; paging presses it by position (narrow clickable strip at the row edge).
  Cards under it are not "covered". When Netflix rebuilds a row after paging, the highlight moves to the same
  film's new copy in that row (`relocate`).
- The film panel's title area (logo plus Resume / + / Like) looked like a picture tile and swallowed its buttons:
  a box with 3+ visible buttons is never a tile. OK on a card now moves into the panel, onto Play / Resume (waiting
  while it slides in).
- Netflix starts its video before attaching it to the page, so the `play` event never reached the page: a 1 s check
  for playing videos now catches it, and OK > Play goes straight to full screen. Trailers in panels never count.
- Verified: rows (Right one film at a time with paging, Left back, Left on the first film stops), panel, Resume >
  full screen, Left/Right skip 10 s (Netflix's own), OK pauses, Back returns to the panel.

## Stage 6, round 5 (12 Nov 2026): Continue Watching, volume pop-up, DStv logo
- **Continue Watching:** tvnav.js reports a video you started (`followWatching`) every 30 s and when it pauses or
  ends: title (media session, Netflix's player title, the page title, or the card OK was pressed on), picture
  (media session, YouTube thumbnail, the card's picture, og:image), the page (YouTube with `t=`; Netflix without its
  tracking), position and length; done at 95 %. tvnav-host.ps1 keeps the latest per app in
  `%LOCALAPPDATA%\TVLauncher\continue\<profile>.json` (removed when done). The helper's `GET /continue` maps
  profiles to apps (same site only, up to 3 weeks old); `POST /launch/{app}` with `{url}` opens the app there (same
  site only) and starts its companion with `-Resume`, which marks the first video as started by you (full screen,
  skipping). Home shows the row under Watch and Listen only when there is something, with a smaller clock and no
  key hints so everything fits; it refreshes when the home screen comes back. Tested on this PC with YouTube
  (resumed at the same second); Netflix/DStv cards tested with sample entries.
- **Volume pop-up** (tv.ahk): a dark pill at the top centre (clear of subtitles), speaker icon by level (Segoe MDL2
  Assets), slim white bar, the number; fades in/out.
- **DStv logo:** dstv.stream's favicon is a plain cyan shape; `icons/dstv.svg` is the DStv mark cropped (viewBox
  only) from the site's own logo file. `iconKeep` stops setup's icon step replacing it.

### Round 5b (12 Nov 2026): volume pop-up redrawn, Prime Video player (tested signed in)
- **Volume pop-up:** the window-control version looked flat, showed the page through its bar (whole-window
  transparency) and clipped the number. Now drawn with GDI+ into a per-pixel-alpha window (`UpdateLayeredWindow`):
  glass pill with gradient, light edge and soft shadow, blue bar with glow and a knob, speaker icon by level, the
  number (or "Muted" in place of the bar); fades with the window's constant alpha.
- **Prime Video:** the title page's muted trailer counted as "started by you" (OK had just opened the page) and went
  full screen, and the fallback made only the inner video box full screen, leaving Prime's controls out. Now:
  muted videos after OK count only when OK was on something like Play; full screen presses the nearest own
  full-screen button (searched outwards from the video), else the biggest box around the video that fits the
  screen; in full screen the controls belong to the full-screen element when the video box holds no buttons.
  Back presses the player's own Close button (shown first: Prime only adds its controls while they show) with a
  real click. Left/Right press the player's skip buttons when the video has no length. Verified: Play > full
  screen with controls, Down/Right along them, Left/Right skip 10 s, OK pauses, Back closes the player.

### Wake from Sleep, round 2 (12 Nov 2026)
Still no wake on the mini PC after setup armed the keyboard/mouse/consumer/system devices with powercfg. New
`scripts/wake-check.ps1` (setup step 5 runs it too): reports the sleep states, each keyboard/mouse with the USB chain
it sits on, the Power Management switches, the armed list, the last wake and recent sleep/wake events, into
`wake-report.txt`; with `-Apply` it turns "may wake" on for every HID/keyboard/mouse/USB device (WMI
`MSPower_DeviceWakeEnable`) and turns "may be turned off to save power" off for USB hubs and controllers
(`MSPower_DeviceEnable`). If it still fails: a USB keyboard in the same port tells receiver limit (keyboard wakes)
from BIOS/USB power (nothing wakes: BIOS Power > Enhanced Power Saving Mode, USB wake options; another port).

## Stage 6, round 6 (12 Nov 2026): standby instead of Sleep
The mini PC cannot be woken from Sleep by any USB device (remote or wired keyboard; Enhanced Power Saving Mode
off, BIOS keyboard power-on on, wake switches set by wake-check.ps1). So "Sleep" is now a TV-style **standby**
(helper `Enter-Standby`): Spotify paused (media key, when now-playing says it plays), sound muted (the old state
kept), screen off (SC_MONITORPOWER). The helper's 1 s loop compares `GetLastInputInfo` with the moment standby
began (the first 2 s absorb the press that started it); any later key or pointer input ends it and restores the
sound. The Power page shows black until `/standby` reports the end, then goes home. Power page Sleep, the sleep
timer's sleep and Screen Off When Idle all use it; the remote's Sleep key (keymap `global.standby`) too, and setup
sets the power and sleep buttons to "turn off the display" so nothing can put the PC into a Sleep it cannot leave.
The plan stays High performance (Balanced would sleep after 30 min). While in standby for 30+ min, the PC restarts
once at 04:00-04:10 and the helper re-enters standby 45 s after the restart (`standby-after-restart` marker).
Idle power of a Haswell i5 Tiny is roughly 8-12 W; staying on is fine for the SSD and electronics (low heat, no
power cycling); clean the vents every few months. Tested here in test mode (requests, Power page); the real
screen-off/mute/wake path and the 04:00 restart still need the TV PC.

## Stage 6, round 8 (23 Nov 2026): full remote test of every app
Every app was driven here with real key presses over the debugging port (scratch driver, windows the TV's size and
scale, signed in: Netflix, YouTube, Prime Video, DStv, Twitch, Spotify; F1 TV signed out; Disney+ not tested, no
account). Fixed in inject/tvnav.js:
- Netflix: the fifth card paged its row the wrong way (direction from the card's left edge); OK on a card now waits
  up to ~3 s for the title panel and goes onto Play/Resume/Next Episode; the panel keeps the highlight (no
  cast/genre/"more" links, no let-go); Up from a wide item (an episode) reaches anything above within its width
  (the season picker); Back/X restores the highlight onto the opening card (by link without tracking extras,
  retried while the panel or page is redrawn, kept across watching from the panel); the player page counts as a
  showing player (controls kept up, Back hides them first).
- YouTube: "Skip navigation" is never a stop; Left/Right "level" no longer reaches up to the chip bar; the side menu
  and top bar keep Up/Down in them (Up on the top bar still scrolls the page); Back from a full-screen video goes
  back (hidden 0x0 "Close" buttons were pressed instead; and the back now waits for fullscreenchange); OK on the
  gear goes into its menu (the site's focused item, else the nearest new menu item); Shorts get Up/Down; the home
  preview player carried onto /watch is re-checked after an address change, so the video goes full screen.
- Prime Video: links drawn as buttons are never stepped over; things lying mostly under the current item count as
  in line; wide items set the column near their left edge; hover-only play buttons over a picture are stops; the
  page pointer is parked off the page after keys on every site (a resting pointer opened previews over the next
  row); the control bar is looked for again until it has faded in; OK on something playable never puts the
  highlight on the player's buttons (Right then moved to Next Episode).
- DStv: banner trailers (a Watch/Play button showing over the video) never count as yours; videos on player pages
  (/play, /watch, /player) and the next video after one of yours count; auto full screen is only suppressed after
  you left it yourself on that page; Down in a player picks Skip Ad/Intro/Recap first.
- All: with no highlight, Down starts on the main Play/Watch/Resume button (whole short label, upper part of the
  screen); otherwise the nearest thing, no column; Up/Down stay inside a self-scrolling area while it has more
  (Spotify's middle part). Twitch tags and Spotify's per-card play buttons are not stops.
Not fixed: F1 TV's cookie pop-up and DStv's adverts live in cross-site frames (separate processes) the page script
cannot reach (touchpad once; Down during a DStv advert moves behind the player). Spotify: Up from the first song
passes the pinned Play bar. Twitch home: the big featured stream is not a stop.

## Stage 6, round 9 (24 Nov 2026): phone remote, updates from GitHub
- **Phone remote.** helper.ps1 runs a second HttpListener on `http://+:8766/` (settings.remotePort; falls back to
  localhost without the URL reservation). `GET /` serves launcher/remote/index.html (a phone page in the launcher's
  style: D-pad, OK, Back, Home, media keys, volume with a level bar, a "type on the TV" box with Press OK after and
  Clear on TV, what Spotify plays). The buttons (`/api/key/*`, `/api/text`, `/api/erase`, `/api/status`) need the
  header `X-Remote-Key`; the key is in helper.json (`remoteKey`) and reaches the phone only through the QR code's
  `#k=` (the part after # is never sent to a server; the page keeps it in localStorage). Keys are sent with
  SendInput (Native.cs `Keys`), so tv.ahk sees them like the real remote's (Home, volume pop-up) and they wake
  standby. Test mode only sends them when a TV window is in front. QR: qrcode-generator 1.4.4 (MIT), vendored in
  launcher/js/vendor. Setup step 12: `netsh http add urlacl` for the TV user and a firewall rule for LocalSubnet on
  Private/Domain networks (warns when the network is Public); uninstall removes both. Tested here: pairing refused
  without the key, status, keys, typing (incl. é), clearing; the page at phone size; the QR dialog.
- **Updates.** config/updates.json names the repository (private: tristenherbst12-source/tv-os, main). The helper
  reads `VERSION` and the latest commit through the GitHub API every 6 h (first 2 min after start) with the token
  setup step 13 stores DPAPI-encrypted (`%LOCALAPPDATA%\TVLauncher\github-token.bin`; checked against the API before
  it is saved). A higher VERSION is an update: js/update.js shows "New Update Available" (Update Now / Later, asked
  again after 12 h), Settings > Updates checks and installs by hand. Install: zipball to %TEMP%\tv-update, then the
  new version's scripts/apply-update.ps1 copies it over the install folder (robocopy /E, without settings.json,
  helper-token.js, wake-report.txt; nothing is deleted), notes whether setup.ps1/setup-lib.ps1 changed, writes
  last-update.json and stops the TV windows, hotkeys and helper; start.ps1 starts them again on the new files.
  Refuses folders with .git. Tested here: the check (404 without a token is reported as "needs a GitHub token"),
  the pop-up and its keys, the Settings row, the "Updated to" note, apply-update.ps1 on throwaway copies. Not
  tested: a real download (no token on this PC) and the restart on the TV.
- **YouTube TV interface:** checked again with a Tizen user agent: still "You are being directed to youtube.com".
  Unchanged decision (see above): no further attempts, as that would mean defeating Google's browser checks.
- **Repository made public (24 Nov):** a fine-grained token expires (at most a year), which would stop updates.
  Public needs none: setup step 13 just confirms the repository is public; the helper sends a stored token only if
  there is one and retries without it when GitHub refuses it (401). Checked before going public: no secrets in the
  history (helper-token.js, github-token.* and settings are ignored; settings.json holds no PIN). Tested the real
  check against the public repository with no token, and with a refused token stored.
- **First TV PC run (24 Nov):** setup said GitHub could not be reached (so it asked for a token) and Settings >
  Updates "could not connect to GitHub", while Edge streamed fine; the phone got ERR_ADDRESS_UNREACHABLE on the
  address in the QR code (so the remote was listening on the network). Changes: the helper falls back to curl.exe
  when PowerShell's web access gets no answer (tested: VERSION, commit and the zip download) and logs the whole
  error chain; setup step 13 uses the same fallback and asks for no token when GitHub cannot be reached at all;
  setup step 12 sets a Public network to Private; new scripts/net-check.ps1 (-Apply) reports DNS, port 443, proxy,
  .NET strong crypto, clock, PowerShell vs curl.exe, the remote's listener, URL reservation, firewall rule and
  profiles, and a request to the remote from the PC itself, to net-report.txt. Unreachable from the phone with all
  of that fine = the router isolates Wi-Fi clients.
- **Media keys did nothing on the TV (24 Nov):** play/pause, next and previous (remote and phone) reached no player
  on the home screen, the screensaver or even in Spotify. Without Explorer nothing routes the media keys to the
  media session, and with several Edge processes open the keys were not Spotify's. Now tv.ahk catches
  Media_Play_Pause/Next/Prev and asks the helper (`POST /media/{playpause|next|prev}`): when Spotify's window is
  open and the launcher, Spotify or nothing is in front (or standby), the helper connects to the Spotify window's
  debugging port (each tvnav-host writes its port to data\ports\<name>.txt) and clicks Spotify's own
  `control-button-playpause` / `-skip-forward` / `-skip-back` (Runtime.evaluate, userGesture). Otherwise AHK sends
  the key on to the app in front. The phone remote's media buttons take the same path. Tested here: play, pause,
  next (the song changed), previous; another TV window in front leaves Spotify alone.
- **Phone remote as an installable app (24 Nov):** Chrome on Android only offered a shortcut ("This app can't be
  installed"): installing needs a secure context, and http://<TV>:8766 is not one. Chosen: the phone's Chrome flag
  "Insecure origins treated as secure" for the TV's address (README). For a clean install the remote now has PNG
  icons (192, 512, maskable 512; rendered from icon.svg / icon-maskable.svg with headless Edge), a manifest with
  id/scope, and sw.js (network first, keeps the page for when the TV is off; /api/ always live), registered only in
  a secure context. The helper serves the remote's files as bytes now (the PNGs). Checked over CDP on
  http://localhost:8766 (secure like the flagged address): no manifest or installability errors, worker active.
