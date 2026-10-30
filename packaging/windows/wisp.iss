; Wisp Windows installer script (Inno Setup 6).
; CI usage:
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DAppVersion=1.0.14 /O. packaging\windows\wisp.iss
; /DAppVersion comes from the git tag; /O. outputs the installer to the repo root.
; NOTE: keep this file ASCII-only -- Inno Setup misreads UTF-8 without BOM.

#define AppName "Wisp"
#define AppPublisher "YuMEHa"
#define AppURL "https://github.com/yunyu697/wisp"

[Setup]
; AppId is fixed so upgrades/uninstalls always target the same app.
AppId={{7C1F4D2A-9B3E-4E68-A5D1-2F8C0B6A9E14}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
DefaultDirName={autopf}\Wisp
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputBaseFilename=wisp-windows-x64-{#AppVersion}-setup
OutputDir=.
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
Architectures=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; The app installs into Program Files; per-user install would not need admin.
PrivilegesRequired=admin
UninstallDisplayIcon={app}\wisp.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\wisp.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\wisp.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\wisp.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
