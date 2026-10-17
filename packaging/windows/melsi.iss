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
CloseApplications=no
RestartApplications=no
ChangesAssociations=yes
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[CustomMessages]
english.MelsiMustStop=Disconnect the VPN in Melsi, then fully quit Melsi and try again. The application and its VPN service must be stopped before installing, updating or uninstalling.
russian.MelsiMustStop=Отключите VPN в Melsi, затем полностью закройте приложение и повторите попытку. Перед установкой, обновлением или удалением приложение и его VPN-служба должны быть остановлены.
english.MelsiProcessCheckFailed=Could not verify that Melsi has stopped. Close Melsi and try again. Setup cannot safely continue while the running processes cannot be checked.
russian.MelsiProcessCheckFailed=Не удалось проверить, завершена ли работа Melsi. Закройте приложение и повторите попытку. Установка или удаление не могут продолжиться без проверки запущенных процессов.

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

[UninstallDelete]
Type: files; Name: "{app}\melsi-core.pid"

[Code]
function CheckMelsiStopped: String;
var
  Locator, Services, Processes: Variant;
begin
  Result := '';
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    { Bound the WMI connection wait; use the current security context. }
    Services := Locator.ConnectServer('.', 'root\CIMV2', '', '', '', '', 128);
    { Check the UI too: it can reconnect the detached core. Do not restrict
      this to the installer account, since elevation may use another user. }
    Processes := Services.ExecQuery(
      'SELECT Name FROM Win32_Process WHERE Name = ''{#CoreExe}'' OR Name = ''{#AppExe}''');
    if Processes.Count > 0 then
      Result := CustomMessage('MelsiMustStop');
  except
    Log('Unable to check Melsi processes: ' + GetExceptionMessage);
    Result := CustomMessage('MelsiProcessCheckFailed');
  end;
  if Result <> '' then
    Log(Result);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  { A forced core exit skips system-proxy restoration. Let Melsi perform
    graceful disconnect before any installed files can be replaced. }
  Result := CheckMelsiStopped;
end;

function InitializeUninstall: Boolean;
var
  Message: String;
begin
  Message := CheckMelsiStopped;
  Result := Message = '';
  if not Result then
    SuppressibleMsgBox(Message, mbError, MB_OK, IDOK);
end;
