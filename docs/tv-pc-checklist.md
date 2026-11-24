# Mini PC checklist (stage 6)

Everything that can only be tested on the TV PC itself. Follow README.md to install, then tick these off.
Write down anything that fails (what you pressed, what happened) so it can be fixed.

## Copying the folder

From the dev PC, copy to a USB stick without the dev-only parts:

```powershell
robocopy C:\Users\trist\OneDrive\Dokumente\appdev\tv-os E:\TVLauncher /E /XD .git design .claude /XF helper-token.js
```

(`E:` is the USB stick.) On the TV PC, copy `E:\TVLauncher` to `C:\TVLauncher`.

## Setup (README steps 4–5)
- [ ] Preview runs as the `TV` user in an admin window; only expected `[check]` lines.
- [ ] `-Apply` asks for `SETUP` and **asks for the password**, and rejects a wrong one.
- [ ] AutoHotkey gets installed by winget.
- [ ] Restart: signs in by itself (no "invalid password"), no lock screen, home screen appears (no Windows
      desktop, no taskbar).
- [ ] Running setup again shows almost everything as `[ok]`.

## Home screen and performance (Haswell iGPU)
- [ ] Wallpaper drifts smoothly; moving between tiles feels instant.
- [ ] If not: Lite Mode (L key or Settings) fixes it. Note which one you needed.
- [ ] Real icons on the tiles (DStv shows a TV symbol on purpose).
- [ ] The Watch row slides when you move right past the 6th tile (8 tiles: up to Spotify).
- [ ] "Next Session" chip shows; Race Calendar loads; unplug the network and it still shows the saved calendar.

## Remote
- [ ] **Home on the home screen stays on the home screen** (no Edge page).
- [ ] **Search button does nothing.**
- [ ] **The pointer disappears** when you press a button or leave the touchpad for 3 s, and comes back (where it
      was) when you touch the touchpad.
- [ ] Home returns home from every app; **holding Back** returns home; a short Back goes back inside apps.
- [ ] **Volume buttons change the volume** and the volume pop-up appears at the top (also inside apps); mute
      shows a crossed-out speaker.
- [ ] Play/pause works in the apps.
- [ ] Settings > Remote Button Test: anything without a "Launcher Action" is noted.

## Apps (sign in to each once; the window keeps the login)
For each of YouTube, Netflix, Prime Video, Disney+, DStv, F1TV, Twitch, Spotify:
- [ ] Opens full screen, **no title bar**, text readable from the couch (scale 125%, YouTube 150%).
- [ ] **Arrows move a blue highlight**: Left/Right along a row (the row slides on past the last visible card), Up/Down
      to the next row of cards (not onto titles or "See more"), staying in the same column. Right at the end of a row
      does nothing.
- [ ] OK opens what it is on (Prime Video cards, profile button and its menu too), Back goes back a page.
- [ ] Trailers that play by themselves (Prime, Netflix banners) do not take over Left/Right, and never go full screen.
- [ ] Prime Video: Play goes full screen with its controls (Down shows them); Left/Right skip; Back closes the player
      and returns to the title page.
- [ ] **Opening a video (OK) goes straight to full screen** (no side list of videos). Left/Right skip 10 s, OK
      pauses/plays.
- [ ] In full screen, Down shows the controls with the highlight on Pause; Right reaches the gear; OK, Up, OK opens
      Quality with the highlight in the list; choosing one goes back to watching. Back hides the controls; Back
      again leaves the video, back to where you came from.
- [ ] YouTube plays at 1080p by itself (gear > Quality shows 1080p).
- [ ] Plays in 1080p without stuttering (YouTube: H.264 is forced).
- [ ] Home closes it and the home screen comes back.
- [ ] Note any page where the highlight cannot reach something, or lands somewhere odd (site + what you pressed).
- [ ] Netflix: the highlight never gets stuck on a card's pop-up preview, and each arrow moves one film. Right
      at the end of the screen pages the row on; Left on a row's first film does nothing (no jump to the end). While
      watching, Left/Right skip 10 s.
- [ ] DStv: profiles, channels and cards can all be reached; in a channel, Down shows the control bar and Right
      goes along it. Trailers on the home page do not jump to full screen.
- [ ] Spotify: big enough to read; Down goes through the playlists on the left; in a playlist each song is one stop
      and OK plays it.
- [ ] Spotify: keeps playing after Home; the home screen shows the song (moving bars while playing, grey when
      paused); opening the tile again brings the same window back.
- [ ] Netflix: OK on a card puts the highlight on Play/Resume in its panel; Back puts it back on the card; Up from
      the first episode reaches the season picker; in the player, Down shows the controls and Back hides them.
- [ ] YouTube: OK on a video goes full screen (also the second time); the gear's menu can be used; Back leaves the
      video for the list; on a Short, Down is the next Short.
- [ ] Prime Video: Watch now under the banner can be reached; episodes on a series page can be reached; while
      watching, Right/Left skip 10 s (the highlight never lands on Skip Recap / Next Episode by itself).
- [ ] DStv: picking a profile does not start the home trailer full screen; a catch-up episode goes full screen
      after its advert, and Right/Left skip 10 s.
- [ ] Logins still there after a restart.

## Phone remote and updates
- [ ] Setup step 12 done; the network is Private. Settings > Phone Remote shows the TV's address (not
      "localhost") and a QR code; the phone opens the remote page from it.
- [ ] Arrows, OK, Back, Home, play/pause and volume work from the phone; typing a search into YouTube works;
      a button on the phone wakes the TV from standby.
- [ ] Setup step 13 stored the GitHub token; Settings > Updates says "Up to Date" (not "needs a GitHub token").
- [ ] After the next pushed version: the home screen shows "New Update Available"; Update Now installs it and the
      home screen comes back saying "Updated to ...".

## Continue Watching
- [ ] Watch something for a minute in YouTube, Netflix or DStv, press Home: a Continue Watching row shows it
      (picture, title, time left).
- [ ] OK on it opens the app right there, full screen (YouTube at the same point).
- [ ] DStv's tile shows the DStv logo.

## Screensaver
- [ ] Home on the home screen starts it: photos, time, date (and the Spotify song while one plays). Any button
      ends it, and that button does nothing else.
- [ ] Left alone on the home screen for 5 minutes: it starts by itself. It never starts while an app is open.
- [ ] Settings > Screensaver changes the time or turns it off.

## Settings and power (real, not test mode)
- [ ] **No "Test Mode" badge** in Settings or Power.
- [ ] Network Speed Test gives sensible numbers.
- [ ] Sound Output switches between the TV and Bluetooth headphones/soundbar.
- [ ] Wi-Fi and Bluetooth: the Settings page opens in front (Bluetooth may open Windows' "Add a device" instead);
      Home comes back from it. If not, bring back `helper.log`.
- [ ] Screen Off When Idle: the TV goes to standby, and a remote button wakes it.
- [ ] Power > Standby: the screen goes off and the sound mutes; any remote button brings the home screen back at
      once, with the sound as it was. Spotify pauses on standby.
- [ ] The remote's power button: standby (or at least the screen goes off). Note what Remote Button Test shows for it.
- [ ] Left in standby overnight: it restarted around 04:00 and is in standby again in the morning.
- [ ] Sleep timer (set 30 min) goes to standby / shuts down.
- [ ] Restart and Shut Down work.
- [ ] **Desktop PIN: set one with the remote, then Windows Desktop with the same PIN opens the desktop.** If it
      says "Wrong PIN", note it: `logs\helper.log` then shows how many digits arrived.
- [ ] Ctrl+Alt+Shift+D on a keyboard does the same; restarting brings the TV screen back.

## Overnight
- [ ] Left on the home screen overnight: still responsive in the morning, no Windows pop-ups or update restarts
      in the evening.

## Logs to bring back if something fails
`C:\Users\TV\AppData\Local\TVLauncher\logs\helper.log`, `start.log` and `tvnav-host.log`.
