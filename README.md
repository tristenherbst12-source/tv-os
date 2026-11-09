# TV Launcher

A home screen for the TV mini PC. When the PC starts, it signs in by itself and shows this home screen instead of the
Windows desktop: YouTube, Netflix, Prime Video, Disney+, F1TV, Spotify, a browser, the race calendar, settings and
power, all driven with the remote.

This guide sets it up on a fresh Windows 10 Pro install. It takes about an hour, most of it waiting for Windows and
the apps.

---

## What you need

- The mini PC on Windows 10 Pro, connected to the TV with the DisplayPort-to-HDMI cable (it carries the sound).
- The remote's USB receiver plugged in.
- A keyboard and mouse for setting up (not needed afterwards).
- This `TVLauncher` folder on a USB stick.
- Your logins for Netflix, Prime Video, Disney+, Spotify, YouTube and F1TV, and a Microsoft account for the
  Microsoft Store.

## 1. Prepare Windows

1. **Use a local account called `TV`.** Automatic sign-in only works with a local account (not one that signs in
   with a Microsoft email).
   - During Windows setup, choose an offline/local account. Or, later:
     Settings > Accounts > Family & other users > Add someone else to this PC > "I don't have this person's sign-in
     information" > "Add a user without a Microsoft account".
   - Give it a password. Make it an **administrator** (Change account type > Administrator).
   - Sign in as `TV` once, so Windows creates its folders. Do everything below while signed in as `TV`.
2. **Update Windows** (Settings > Update & Security > Windows Update) until nothing is left, then restart.
3. **Enrol in Extended Security Updates (ESU)**, the free consumer programme that keeps Windows 10 getting security
   fixes until 12 October 2027: Settings > Update & Security > Windows Update > "Enroll now".
4. **Sound:** right-click the speaker icon > Sound settings, and choose the TV as the output. (You can switch later
   from the launcher's Settings > Sound Output.)

## 2. Copy the launcher

Copy the whole `TVLauncher` folder to **`C:\TVLauncher`**. Keep it there: the PC starts it from that folder.
(Not the Desktop, Downloads or OneDrive.)

## 3. Install the apps

Open the **Microsoft Store**, sign in to the Store with your Microsoft account (only the Store, not Windows), and
install:

- **Netflix**, **Prime Video**, **Disney+**, **Spotify**

Open each one once and sign in. YouTube and F1TV are websites; you sign in to those in step 6.

## 4. Preview the setup

Click Start, type `PowerShell`, right-click **Windows PowerShell** > **Run as administrator**, then:

```powershell
cd C:\TVLauncher
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1
```

This changes nothing. It lists everything setup would do, with each setting's current value:
`[ok]` is already right, `[would]` would be changed, `[check]` needs your attention.
Read the `[check]` lines (for example a missing app) and sort them out first.

## 5. Run the setup

Same window:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1 -Apply
```

Type `SETUP` when it asks, and the `TV` account's Windows password when it asks for that. What it does:

1. Checks the Windows version and reminds you about ESU.
2. Sets the time zone to South Africa.
3. Removes preinstalled extras (news, weather, Xbox overlays, Solitaire and so on) and turns off tips, ads,
   suggestions, search highlights, notification pop-ups and background apps. Netflix, Prime Video, Disney+,
   Spotify, the Store and Edge are never touched.
4. Windows Update: only restarts between 02:00 and 08:00, never in the evening.
5. Power: never sleeps on its own (the launcher's own Screen Off setting handles the screen), keeps the remote's USB
   receiver awake, no password after waking, hibernation off.
6. Signs in to `TV` automatically. The password is stored encrypted by Windows, not as plain text.
7. Starts the TV launcher instead of the Windows desktop, **for the `TV` account only**.
8. Installs AutoHotkey v2 (it makes the remote's Home and Back buttons work everywhere).
9. Checks that Netflix, Prime Video, Disney+ and Spotify are installed.
10. Copies each app's own icon onto its tile.
11. Sets Edge up for the TV windows (no account sign-in or sync in them, no welcome pages).

You can run it again any time; it only changes what is different. To leave steps out, add for example
`-Skip debloat,autologin`.

## 6. Restart and finish

Restart the PC. It should sign in by itself and open the home screen. Then, with the remote:

1. Open **YouTube** and sign in (the window keeps the login). Same for **F1TV**.
2. Open Netflix, Prime Video, Disney+ and Spotify once to check they are still signed in.
3. **Settings > Remote Button Test:** press every button on the remote. Each one shows what it sends. If Home, Back,
   OK or the arrows show nothing in the "Launcher Action" column, note the values and update
   `C:\TVLauncher\config\keymap.json` (or ask for help). Hold Back for 2 seconds to leave.

## Using it

| Button | What it does |
|---|---|
| Arrows, OK | Move and open |
| Back | Back inside an app; **hold** it to go to the home screen |
| Home | Back to the home screen from any app |
| L (keyboard) | Lite Mode on/off (less animation, if the PC struggles) |

- **Spotify** keeps playing when you press Home; the other apps close.
- **Settings** has the volume, sound output, sleep timer, screen-off timer, wallpaper, Lite Mode, Wi-Fi and Bluetooth.
- **Power** has Sleep, Restart and Shut Down. Any button on the remote wakes the PC from Sleep.

## Getting to the Windows desktop

For maintenance (installing things, updates, files):

- **Settings > Windows Desktop** (asks for the PIN if you set one under Settings > Desktop PIN), or
- **Ctrl + Alt + Shift + D** on a keyboard, or
- if the screen is ever black: **Ctrl + Alt + Del** > Task Manager > File > Run new task > `explorer` > OK.

Restarting the PC brings the TV home screen back.

## Updating the launcher

Copy the new files over `C:\TVLauncher`, but keep your `config\settings.json` (it holds your settings and desktop
PIN). Then run setup again (step 5) and restart, or use Settings > Restart Launcher.

## Undoing it

From the Windows desktop, in an administrator PowerShell:

```powershell
cd C:\TVLauncher
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\uninstall.ps1           # preview
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\uninstall.ps1 -Apply    # do it
```

This gives `TV` the normal desktop back, turns off automatic sign-in, deletes the stored password and removes the
Edge settings. Add `-RemoveData` to also delete the TV windows' saved logins. Removed apps, power and Windows Update
settings stay as they are.

## When something is wrong

- **The home screen does not come back after an app:** press Home, or hold Back.
- **A tile says "App Not Installed":** install that app from the Store (step 3).
- **Everything is slow or stutters:** press L or turn on Settings > Lite Mode.
- **Logs:** `C:\Users\TV\AppData\Local\TVLauncher\logs` (`helper.log` and `start.log`).
- **Trying it on another PC without changing it:** `scripts\start.cmd -Windowed` runs it in a window in test mode
  (Sleep, Restart and Shut Down only pretend).
