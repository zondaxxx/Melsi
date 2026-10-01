; Inno Setup 6.3+ script for the Melsi Windows installer.
;
; Build (from the repo root):
;   iscc /DAppVersion=1.2.3 ^
;        /DSourceDir=app\build\windows\x64\runner\Release ^
;        /DOutputDir=dist ^
;        packaging\windows\melsi.iss
;
; SourceDir/OutputDir given via /D must be RELATIVE to the repo root
; (RepoRoot = this script's directory + ..\..).

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define RepoRoot AddBackslash(SourcePath) + "..\.."
#ifndef SourceDir
  #define SourceDir "app\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "dist"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "Melsi-" + AppVersion + "-windows-x64-setup"
#endif
; Numeric part only (1.2.3-abc -> 1.2.3) for VersionInfoVersion.
#if Pos("-", AppVersion) > 0
  #define NumericVersion Copy(AppVersion, 1, Pos("-", AppVersion) - 1)
#else
  #define NumericVersion AppVersion
#endif

#define AppName "Melsi"
#define AppExe "melsi.exe"
#define CoreExe "melsi-core.exe"
#define AppPublisher "Melsi"
#define AppUrl "https://github.com/zondaxxx/melsi"

[Setup]
AppId={{94F602EF-2E3A-4BD1-BA94-D5CCC2E37FD0}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
VersionInfoVersion={#NumericVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#RepoRoot}\{#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
SetupIconFile={#RepoRoot}\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no
ChangesAssociations=yes
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "thirdpartylinks"; Description: "Open sing-box://, clash:// and hiddify:// subscription links with Melsi"; GroupDescription: "Links:"

[Files]
Source: "{#RepoRoot}\{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; melsi:// is ours: always registered.
Root: HKA; Subkey: "Software\Classes\melsi"; ValueType: string; ValueName: ""; ValueData: "URL:Melsi Protocol"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\melsi"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\melsi\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"",0"
Root: HKA; Subkey: "Software\Classes\melsi\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""
; Third-party import schemes (optional task, on by default).
Root: HKA; Subkey: "Software\Classes\sing-box"; ValueType: string; ValueName: ""; ValueData: "URL:sing-box Protocol"; Flags: uninsdeletekey; Tasks: thirdpartylinks
Root: HKA; Subkey: "Software\Classes\sing-box"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: thirdpartylinks
Root: HKA; Subkey: "Software\Classes\sing-box\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"",0"; Tasks: thirdpartylinks
Root: HKA; Subkey: "Software\Classes\sing-box\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""; Tasks: thirdpartylinks
Root: HKA; Subkey: "Software\Classes\clash"; ValueType: string; ValueName: ""; ValueData: "URL:Clash Protocol"; Flags: uninsdeletekey; Tasks: thirdpartylinks
Root: HKA; Subkey: "Software\Classes\clash"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: thirdpartylinks
Root: HKA; Subkey: "Software\Classes\clash\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"",0"; Tasks: thirdpartylinks
Root: HKA; Subkey: "Software\Classes\clash\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""; Tasks: thirdpartylinks
Root: HKA; Subkey: "Software\Classes\hiddify"; ValueType: string; ValueName: ""; ValueData: "URL:Hiddify Protocol"; Flags: uninsdeletekey; Tasks: thirdpartylinks
Root: HKA; Subkey: "Software\Classes\hiddify"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: thirdpartylinks
Root: HKA; Subkey: "Software\Classes\hiddify\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"",0"; Tasks: thirdpartylinks
Root: HKA; Subkey: "Software\Classes\hiddify\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""; Tasks: thirdpartylinks

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Runs before any file is removed: stop the elevated core first, then the UI.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /T /IM {#CoreExe}"; Flags: runhidden waituntilterminated; RunOnceId: "KillCore"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /T /IM {#AppExe}"; Flags: runhidden waituntilterminated; RunOnceId: "KillApp"

[UninstallDelete]
Type: files; Name: "{app}\melsi-core.pid"

[Code]
procedure KillImage(const Image: String);
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM ' + Image, '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  { Upgrades: make sure no old binaries are locked. }
  KillImage('{#CoreExe}');
  KillImage('{#AppExe}');
  Result := '';
end;
