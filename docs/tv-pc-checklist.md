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
- [ ] **Volume buttons change the volume** and a small volume bar appears (also inside apps); mute works.
- [ ] Play/pause works in the apps.
- [ ] Settings > Remote Button Test: anything without a "Launcher Action" is noted.

## Apps (sign in to each once; the window keeps the login)
For each of YouTube, Netflix, Prime Video, Disney+, DStv, F1TV, Twitch, Spotify:
- [ ] Opens full screen, **no title bar**, text readable from the couch (scale 125%, YouTube 150%).
- [ ] **Arrows move a blue highlight**: Left/Right along a row (the row slides on past the last visible card), Up/Down
      to the next row of cards (not onto titles or "See more"), staying in the same column. Right at the end of a row
      does nothing.
- [ ] OK opens what it is on (Prime Video cards, profile button and its menu too), Back goes back a page.
- [ ] Trailers that play by themselves (Prime, Netflix banners) do not take over Left/Right.
- [ ] Playing a video: Left/Right skip 10 s, OK goes full screen then pauses, Back leaves full screen.
- [ ] Plays in 1080p without stuttering (YouTube: H.264 is forced).
- [ ] Home closes it and the home screen comes back.
- [ ] Note any page where the highlight cannot reach something, or lands somewhere odd (site + what you pressed).
- [ ] Spotify: keeps playing after Home; opening the tile again brings the same window back.
- [ ] Logins still there after a restart.

## Settings and power (real, not test mode)
- [ ] **No "Test Mode" badge** in Settings or Power.
- [ ] Network Speed Test gives sensible numbers.
- [ ] Sound Output switches between the TV and Bluetooth headphones/soundbar.
- [ ] Bluetooth: pairing page opens; Home comes back from it.
- [ ] Screen Off When Idle: the TV goes to standby, and a remote button wakes it.
- [ ] Sleep: PC sleeps; a remote button wakes it straight to the home screen (no password).
- [ ] Sleep timer (set 30 min) really sleeps / shuts down.
- [ ] Restart and Shut Down work.
- [ ] **Desktop PIN: set one with the remote, then Windows Desktop with the same PIN opens the desktop.** If it
      says "Wrong PIN", note it: `logs\helper.log` then shows how many digits arrived.
- [ ] Ctrl+Alt+Shift+D on a keyboard does the same; restarting brings the TV screen back.

## Overnight
- [ ] Left on the home screen overnight: still responsive in the morning, no Windows pop-ups or update restarts
      in the evening.

## Logs to bring back if something fails
`C:\Users\TV\AppData\Local\TVLauncher\logs\helper.log`, `start.log` and `tvnav-host.log`.
