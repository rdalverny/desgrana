; Inno Setup script for Desgrana (Windows GUI).
; Packages the dist\desgrana bundle (desgrana-gui.exe + Qt and Swift runtime DLLs)
; into a single setup.exe with a Start Menu entry and an uninstaller.
; Invoked by CI; AppVersion / BundleDir / OutDir are passed via ISCC /D switches.
; The defaults below let it also run locally: iscc packaging\win\desgrana.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef BundleDir
  #define BundleDir "..\..\dist\desgrana"
#endif
#ifndef OutDir
  #define OutDir "..\..\dist"
#endif

[Setup]
AppId={{B7E3F1C2-4A6D-4B8E-9F1A-2C5D7E9A0B34}
AppName=Desgrana
AppVersion={#AppVersion}
AppPublisher=Romain d'Alverny
VersionInfoVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}
InfoBeforeFile=privacy.txt
DefaultDirName={autopf}\Desgrana
DefaultGroupName=Desgrana
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\desgrana-gui.exe
SetupIconFile=desgrana.ico
OutputDir={#OutDir}
OutputBaseFilename=desgrana-{#AppVersion}-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Tasks]
Name: "updatecheck"; Description: "Check for updates once a month"; Flags: unchecked

; QSettings falls back from HKCU to HKLM: this sets the machine default,
; the user setting still wins.
[Registry]
Root: HKLM; Subkey: "Software\elephathom"; Flags: uninsdeletekeyifempty
Root: HKLM; Subkey: "Software\elephathom\Desgrana"; Flags: uninsdeletekeyifempty
Root: HKLM; Subkey: "Software\elephathom\Desgrana\updateCheck"; ValueType: string; ValueName: "enabled"; ValueData: "false"; Tasks: not updatecheck; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\elephathom\Desgrana\updateCheck"; ValueType: none; ValueName: "enabled"; Tasks: updatecheck; Flags: deletevalue uninsdeletekey

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Desgrana"; Filename: "{app}\desgrana-gui.exe"

[Run]
Filename: "{app}\desgrana-gui.exe"; Description: "Launch Desgrana"; Flags: nowait postinstall skipifsilent
