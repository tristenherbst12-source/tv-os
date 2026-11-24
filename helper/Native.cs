// Windows APIs the helper needs. Compiled by helper.ps1 at start (Add-Type), so no build step.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace TVHelper {

  // ---------- shared COM bits ----------
  [StructLayout(LayoutKind.Sequential, Pack = 4)] public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
  [StructLayout(LayoutKind.Explicit)] public struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; [FieldOffset(16)] public IntPtr pad; }

  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    [PreserveSig] int GetCount(out uint c);
    [PreserveSig] int GetAt(uint i, out PROPERTYKEY k);
    [PreserveSig] int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
  }

  static class Com {
    [DllImport("ole32.dll")] public static extern int PropVariantClear(ref PROPVARIANT v);
    public static void Check(int hr) { if (hr < 0) Marshal.ThrowExceptionForHR(hr); }
    public static string ReadString(IPropertyStore ps, Guid fmtid, uint pid) {
      var key = new PROPERTYKEY { fmtid = fmtid, pid = pid };
      PROPVARIANT v;
      if (ps.GetValue(ref key, out v) != 0) return null;
      string s = v.vt == 31 ? Marshal.PtrToStringUni(v.p) : null;   // VT_LPWSTR
      PropVariantClear(ref v);
      return s;
    }
  }

  // ---------- Store app activation ----------
  [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IApplicationActivationManager {
    void ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
                             [MarshalAs(UnmanagedType.LPWStr)] string arguments, int options, out uint processId);
  }
  [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
  class ApplicationActivationManager { }

  public static class Native {
    // Starts a Store app by its AUMID without going through explorer.exe (which would start the full desktop
    // when it is not the shell). Returns the app's process id.
    public static uint Activate(string aumid) {
      var mgr = (IApplicationActivationManager)new ApplicationActivationManager();
      uint pid;
      mgr.ActivateApplication(aumid, null, 0, out pid);
      return pid;
    }

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("powrprof.dll")] static extern bool SetSuspendState(bool hibernate, bool force, bool disableWakeEvent);

    // Windows only lets the foreground process hand over focus. The helper runs in the background,
    // so borrow the foreground thread's input state (and, failing that, the Alt-key trick AutoHotkey uses).
    public static bool ForceForeground(IntPtr h) {
      if (IsIconic(h)) ShowWindow(h, 9);
      IntPtr fg = GetForegroundWindow();
      if (fg == h) return true;
      uint fgThread = GetWindowThreadProcessId(fg, IntPtr.Zero), me = GetCurrentThreadId();
      bool attached = fgThread != me && AttachThreadInput(me, fgThread, true);
      BringWindowToTop(h);
      SetForegroundWindow(h);
      if (attached) AttachThreadInput(me, fgThread, false);
      if (GetForegroundWindow() == h) return true;
      keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero);
      SetForegroundWindow(h);
      return GetForegroundWindow() == h;
    }

    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ps);

    // The window's AppUserModelID (what the taskbar groups by). Store apps, including the ones that are
    // really Edge web apps (Netflix today), carry "<PackageFamilyName>!<AppId>" here.
    public static string WindowAumid(IntPtr h) {
      try {
        Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        IPropertyStore ps;
        if (SHGetPropertyStoreForWindow(h, ref iid, out ps) != 0 || ps == null) return null;
        string s = Com.ReadString(ps, new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);
        Marshal.ReleaseComObject(ps);
        return s;
      } catch { return null; }
    }

    // Turns the display off (any key or mouse movement wakes it).
    public static void MonitorOff() {
      PostMessage(new IntPtr(0xFFFF), 0x0112 /*WM_SYSCOMMAND*/, new IntPtr(0xF170) /*SC_MONITORPOWER*/, new IntPtr(2));
    }

    // When the last key press or pointer movement happened (milliseconds since start-up, as Environment.TickCount).
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO li);
    public static uint LastInputTick() {
      var li = new LASTINPUTINFO(); li.cbSize = (uint)Marshal.SizeOf(li);
      return GetLastInputInfo(ref li) ? li.dwTime : 0;
    }
    // The media play/pause key, as if pressed on a keyboard (pauses Spotify for standby).
    public static void MediaPlayPause() {
      keybd_event(0xB3, 0, 1, UIntPtr.Zero); keybd_event(0xB3, 0, 3, UIntPtr.Zero);
    }

    // Sleep (not hibernate). If hibernation is on, Windows may still choose hybrid sleep.
    public static bool Sleep() { return SetSuspendState(false, false, false); }

    // ---------- Bluetooth: is there a radio? ----------
    [StructLayout(LayoutKind.Sequential)] struct BLUETOOTH_FIND_RADIO_PARAMS { public uint dwSize; }
    [DllImport("bthprops.cpl", SetLastError = true)] static extern IntPtr BluetoothFindFirstRadio(ref BLUETOOTH_FIND_RADIO_PARAMS p, out IntPtr radio);
    [DllImport("bthprops.cpl")] static extern bool BluetoothFindRadioClose(IntPtr find);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static bool HasBluetoothRadio() {
      try {
        var p = new BLUETOOTH_FIND_RADIO_PARAMS { dwSize = (uint)Marshal.SizeOf(typeof(BLUETOOTH_FIND_RADIO_PARAMS)) };
        IntPtr radio;
        IntPtr find = BluetoothFindFirstRadio(ref p, out radio);
        if (find == IntPtr.Zero) return false;
        CloseHandle(radio);
        BluetoothFindRadioClose(find);
        return true;
      } catch { return false; }
    }
  }

  // ---------- Core Audio: volume, mute, playback devices ----------
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo { }

  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
  }

  [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceCollection {
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int Item(uint index, out IMMDevice device);
  }

  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore props);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out int state);
  }

  [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioEndpointVolume {
    [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
    [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
    [PreserveSig] int GetChannelCount(out uint count);
    [PreserveSig] int SetMasterVolumeLevel(float db, ref Guid ctx);
    [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
    [PreserveSig] int GetMasterVolumeLevel(out float db);
    [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
    [PreserveSig] int SetChannelVolumeLevel(uint ch, float db, ref Guid ctx);
    [PreserveSig] int SetChannelVolumeLevelScalar(uint ch, float level, ref Guid ctx);
    [PreserveSig] int GetChannelVolumeLevel(uint ch, out float db);
    [PreserveSig] int GetChannelVolumeLevelScalar(uint ch, out float level);
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
  }

  // Undocumented but long-stable interface (Windows 7-11) used by every audio-switcher tool to change the default device.
  [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPolicyConfig {
    [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr fmt);
    [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, int def, IntPtr fmt);
    [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id);
    [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr endpointFmt, IntPtr mixFmt);
    [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, int def, IntPtr a, IntPtr b);
    [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr period);
    [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
    [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
    [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key, IntPtr value);
    [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key, IntPtr value);
    [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
    [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string id, int visible);
  }
  [ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")] class CPolicyConfigClient { }

  public class AudioDevice {
    public string Id { get; set; }
    public string Name { get; set; }
    public bool IsDefault { get; set; }
  }

  public static class Audio {
    const int eRender = 0, eMultimedia = 1, DEVICE_STATE_ACTIVE = 1, CLSCTX_ALL = 23;

    static IMMDeviceEnumerator Enumerator() { return (IMMDeviceEnumerator)new MMDeviceEnumeratorCo(); }

    static IAudioEndpointVolume Volume() {
      IMMDevice dev;
      Com.Check(Enumerator().GetDefaultAudioEndpoint(eRender, eMultimedia, out dev));
      Guid iid = typeof(IAudioEndpointVolume).GUID;
      object o;
      Com.Check(dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o));
      return (IAudioEndpointVolume)o;
    }

    public static int GetVolume() { float f; Com.Check(Volume().GetMasterVolumeLevelScalar(out f)); return (int)Math.Round(f * 100); }
    public static void SetVolume(int percent) {
      Guid ctx = Guid.Empty;
      Com.Check(Volume().SetMasterVolumeLevelScalar(Math.Max(0, Math.Min(100, percent)) / 100f, ref ctx));
    }
    public static bool GetMute() { bool m; Com.Check(Volume().GetMute(out m)); return m; }
    public static void SetMute(bool mute) { Guid ctx = Guid.Empty; Com.Check(Volume().SetMute(mute, ref ctx)); }

    public static List<AudioDevice> Devices() {
      var e = Enumerator();
      string defId = null;
      IMMDevice def;
      if (e.GetDefaultAudioEndpoint(eRender, eMultimedia, out def) == 0) def.GetId(out defId);
      IMMDeviceCollection col;
      Com.Check(e.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, out col));
      uint n; col.GetCount(out n);
      var list = new List<AudioDevice>();
      for (uint i = 0; i < n; i++) {
        IMMDevice d; if (col.Item(i, out d) != 0) continue;
        string id; d.GetId(out id);
        string name = id;
        IPropertyStore ps;
        if (d.OpenPropertyStore(0 /*STGM_READ*/, out ps) == 0) {
          // PKEY_Device_FriendlyName, e.g. "Speakers (Realtek(R) Audio)" or "LG TV (Intel(R) Display Audio)"
          name = Com.ReadString(ps, new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 14) ?? id;
        }
        list.Add(new AudioDevice { Id = id, Name = name, IsDefault = id == defId });
      }
      return list;
    }

    // Makes the device the default for all roles (console, multimedia, communications).
    public static void SetDefault(string id) {
      var pc = (IPolicyConfig)new CPolicyConfigClient();
      for (int role = 0; role < 3; role++) Com.Check(pc.SetDefaultEndpoint(id, role));
    }
  }

  // ---------- phone remote: key presses and typing, as a keyboard would send them ----------
  public static class Keys {
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION u; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    const uint KEYUP = 2, EXTENDED = 1, UNICODE = 4;

    static INPUT Key(ushort vk, ushort scan, uint flags) {
      var i = new INPUT { type = 1 };
      i.u.ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags };
      return i;
    }
    // One key press (down and up). Arrows, Home, the media and volume keys are "extended" keys.
    public static void Press(ushort vk, bool extended) {
      uint f = extended ? EXTENDED : 0;
      var down = new[] { Key(vk, 0, f) };
      var up = new[] { Key(vk, 0, f | KEYUP) };
      SendInput(1, down, Marshal.SizeOf(typeof(INPUT)));
      System.Threading.Thread.Sleep(30);
      SendInput(1, up, Marshal.SizeOf(typeof(INPUT)));
    }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    // The process of the window in front (test mode only sends keys to the TV's own windows).
    public static uint ForegroundPid() { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return pid; }
    // Ctrl+A (select everything in the text box, so the next Backspace clears it).
    public static void CtrlA() {
      var seq = new[] { Key(0x11, 0, 0), Key(0x41, 0, 0), Key(0x41, 0, KEYUP), Key(0x11, 0, KEYUP) };
      SendInput((uint)seq.Length, seq, Marshal.SizeOf(typeof(INPUT)));
    }
    // Types text into the box that has focus (any characters, as Unicode).
    public static void Type(string text) {
      var list = new List<INPUT>();
      foreach (char c in text) {
        if (c == '\n') { list.Add(Key(0x0D, 0, 0)); list.Add(Key(0x0D, 0, KEYUP)); continue; }
        list.Add(Key(0, c, UNICODE)); list.Add(Key(0, c, UNICODE | KEYUP));
      }
      if (list.Count > 0) SendInput((uint)list.Count, list.ToArray(), Marshal.SizeOf(typeof(INPUT)));
    }
  }
}
