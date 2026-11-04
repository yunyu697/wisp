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
ArchitecturesInstallIn64BitMode=x64compatible
; The app installs into Program Files; per-user install would not need admin.
PrivilegesRequired=admin
; In-app "auto update" runs this installer with /SILENT: silently force-close
; the running Wisp (a busy file would otherwise abort a silent install),
; then relaunch the new build afterwards (see [Run] without skipifsilent).
CloseApplications=force
UninstallDisplayIcon={app}\wisp.exe

[Languages]
; Runner's Inno Setup no longer ships ChineseSimplified.isl; keep default English.
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Relative to this .iss file (packaging/windows/), not to the working directory.
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\wisp.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\wisp.exe"; Tasks: desktopicon

[Run]
; Interactive install: keep the familiar "launch app" checkbox on the finish page.
; skipifsilent is required here -- see the silent entry below.
Filename: "{app}\wisp.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent runasoriginaluser

; Silent install (the in-app "one-click update" runs this installer with /SILENT):
; start the new build automatically. This entry must NOT carry the postinstall
; flag -- /SILENT never shows the finish page, so postinstall entries are never
; executed and the app would simply never come back after an update.
; runasoriginaluser: the setup itself is elevated, but the app must not run as admin.
Filename: "{app}\wisp.exe"; Flags: nowait runasoriginaluser; Check: WizardSilent

[Code]
// The in-app updater starts this installer while Wisp is still running. Wisp
// hides to the tray on WM_CLOSE instead of exiting, so Inno's CloseApplications
// (Restart Manager) cannot stop it and wisp.exe stays locked -- a silent install
// would then abort or leave a half-updated copy. Kill it explicitly before the
// files are copied; [Run] brings the new build back afterwards.
//
// No /T: the elevated installer is created by the AppInfo service, not as a
// child of Wisp, so killing the tree is unnecessary -- and would be dangerous
// if Windows ever reparented it.
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssInstall then
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM wisp.exe', '',
         SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;
