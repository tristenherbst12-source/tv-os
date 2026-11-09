' Silent entry point for the Windows shell (no console window flashes at login).
' setup.ps1 (stage 5) points the TV user's Winlogon Shell at:  wscript.exe "<install>\scripts\start.vbs"
' Waits for start.ps1, so Windows sees the shell as running.
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\start.ps1"""
CreateObject("WScript.Shell").Run cmd, 0, True
