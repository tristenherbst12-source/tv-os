# Mini PC checklist (stage 6)

Everything that could only be tested on the TV PC itself. Follow README.md to install, then tick these off.
Write down anything that fails (what you pressed, what happened) so it can be fixed.

## Copying the folder

From the dev PC, copy to a USB stick without the dev-only parts:

```powershell
robocopy C:\Users\trist\OneDrive\Dokumente\appdev\tv-os E:\TVLauncher /E /XD .git design .claude /XF helper-token.js
```

(`E:` is the USB stick.) On the TV PC, copy `E:\TVLauncher` to `C:\TVLauncher`.

## Setup (README steps 4–5)
- [ ] Preview runs as the `TV` user in an admin window; only expected `[check]` lines.
- [ ] `-Apply` asks for `SETUP` and the password, and rejects a wrong password.
- [ ] AutoHotkey gets installed by winget.
- [ ] Restart: signs in by itself, no lock screen, home screen appears (no Windows desktop, no taskbar).
- [ ] Running setup again shows almost everything as `[ok]`.

## Home screen and performance (Haswell iGPU)
- [ ] Wallpaper drifts smoothly; moving between tiles feels instant.
- [ ] If not: Lite Mode (L key or Settings) fixes it. Note which one you needed.
- [ ] Real icons on all tiles (re-run `scripts\extract-icons.ps1` if one shows a plain glyph).
- [ ] "Next Session" chip shows; Race Calendar loads; unplug the network and it still shows the saved calendar.

## Remote
- [ ] Settings > Remote Button Test: every button shows up. Note the values for any that do not have a
      "Launcher Action" (Home, Back, OK, arrows, volume).
- [ ] Home button returns home from every app; hold Back returns home; tap Back works inside apps.
- [ ] Volume buttons change the volume.
- [ ] Air-mouse pointer works in YouTube and the browser.

## Apps
- [ ] Each tile opens, plays in 1080p, and Home closes it (Spotify: minimises and keeps playing).
- [ ] YouTube: 1080p plays without stuttering (H.264 is forced). Note any "developer mode extensions" pop-up.
- [ ] Netflix / Prime / Disney+ still sign in fine with the Edge settings from setup.
- [ ] YouTube and F1TV keep their logins after a restart.

## Settings and power (real, not test mode)
- [ ] Sound Output switches between the TV and Bluetooth headphones/soundbar.
- [ ] Bluetooth: pairing page opens; Home comes back from it.
- [ ] Screen Off When Idle: the TV goes to standby, and a remote button wakes it.
- [ ] Sleep: PC sleeps; a remote button wakes it straight to the home screen (no password).
- [ ] Sleep timer (set 30 min) really sleeps / shuts down.
- [ ] Restart and Shut Down work.
- [ ] Windows Desktop (with PIN) opens explorer; restarting brings the TV screen back.
- [ ] Ctrl+Alt+Shift+D on a keyboard does the same.

## Overnight
- [ ] Left on the home screen overnight: still responsive in the morning, no Windows pop-ups or update restarts
      in the evening.
