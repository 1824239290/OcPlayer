#ifndef MyAppVersion
  #error "MyAppVersion must be defined"
#endif
#ifndef MyPlatform
  #define MyPlatform "x64"
#endif
#ifndef PublishDir
  #error "PublishDir must be defined"
#endif
#ifndef InstallerDir
  #error "InstallerDir must be defined"
#endif
#ifndef OutputDir
  #error "OutputDir must be defined"
#endif
#ifndef OutputBaseName
  #define OutputBaseName "OcPlayer-" + MyAppVersion + "-" + MyPlatform + "-Setup"
#endif
#ifndef ChineseSimplifiedIsl
  #define ChineseSimplifiedIsl "compiler:Languages\ChineseSimplified.isl"
#endif

[Setup]
AppId={{1EDBADE9-AD55-442B-A1DB-752A2A40B549}
AppName=OcPlayer
AppVersion={#MyAppVersion}
AppVerName=OcPlayer {#MyAppVersion}
AppPublisher=OcPlayer
VersionInfoVersion={#MyAppVersion}
DefaultDirName={autopf}\OcPlayer
DefaultGroupName=OcPlayer
UsePreviousAppDir=yes
UsePreviousPrivileges=yes
UsePreviousGroup=yes
DisableProgramGroupPage=yes
DisableDirPage=no
DisableWelcomePage=no
AppendDefaultDirName=yes
DirExistsWarning=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
MinVersion=10.0.17763
#if MyPlatform == "ARM64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
SetupIconFile={#InstallerDir}\..\src\OcPlayer.Windows\Assets\Branding\OcPlayer.ico
UninstallDisplayIcon={app}\OcPlayer.Windows.exe
UninstallDisplayName=OcPlayer
InfoBeforeFile={#InstallerDir}\notice.rtf
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "{#ChineseSimplifiedIsl}"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\OcPlayer\OcPlayer"; Filename: "{app}\OcPlayer.Windows.exe"; WorkingDir: "{app}"; IconFilename: "{app}\Assets\Branding\OcPlayer.ico"
Name: "{autodesktop}\OcPlayer"; Filename: "{app}\OcPlayer.Windows.exe"; WorkingDir: "{app}"; IconFilename: "{app}\Assets\Branding\OcPlayer.ico"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Software\OcPlayer\Windows\Installer"; ValueType: string; ValueName: "InstallLocation"; ValueData: "{app}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\ocplayer"; ValueType: string; ValueName: ""; ValueData: "URL:OcPlayer OAuth"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\ocplayer"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\ocplayer\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\OcPlayer.Windows.exe"" --bangumi-oauth-callback ""%1"""

[Run]
Filename: "{app}\OcPlayer.Windows.exe"; Description: "{cm:LaunchProgram,OcPlayer}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
const
  InnoUninstallSubkey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{1EDBADE9-AD55-442B-A1DB-752A2A40B549}_is1';
  InstallerMetaSubkey = 'Software\OcPlayer\Windows\Installer';
  UninstallRootSubkey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall';

var
  DetectedExistingDir: String;
  PreviousDirNoticeLabel: TNewStaticText;

function HasExplicitDirParam: Boolean;
var
  I: Integer;
  Arg: String;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    Arg := UpperCase(Trim(ParamStr(I)));
    if Copy(Arg, 1, 5) = '/DIR=' then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function NormalizeInstallDir(const RawPath: String): String;
var
  S: String;
begin
  S := Trim(RawPath);
  if (Length(S) >= 2) and (S[1] = '"') and (S[Length(S)] = '"') then
    S := Copy(S, 2, Length(S) - 2);
  S := Trim(S);
  if S <> '' then
    S := RemoveBackslashUnlessRoot(S);
  Result := S;
end;

function IsPathUnder(const CandidatePath, BaseDir: String): Boolean;
var
  NormCandidate: String;
  NormBase: String;
begin
  Result := False;
  NormCandidate := NormalizeInstallDir(CandidatePath);
  NormBase := NormalizeInstallDir(BaseDir);
  if (NormCandidate = '') or (NormBase = '') then
    Exit;
  if CompareText(NormCandidate, NormBase) = 0 then
  begin
    Result := True;
    Exit;
  end;
  NormBase := AddBackslash(NormBase);
  Result := (Length(NormCandidate) >= Length(NormBase)) and
            (CompareText(Copy(NormCandidate, 1, Length(NormBase)), NormBase) = 0);
end;

function IsPathCompatibleWithCurrentMode(const CandidatePath: String): Boolean;
begin
  Result := True;
  if IsAdminInstallMode then
  begin
    if IsPathUnder(CandidatePath, ExpandConstant('{localappdata}')) or
       IsPathUnder(CandidatePath, ExpandConstant('{userappdata}')) then
      Result := False;
  end
  else
  begin
    if IsPathUnder(CandidatePath, ExpandConstant('{commonpf}')) then
      Result := False;
  end;
end;

function QueryRecordedInstallLocation(const RootKey: Integer; var InstallDir: String): Boolean;
var
  RawPath: String;
begin
  Result := False;
  if RegQueryStringValue(RootKey, InnoUninstallSubkey, 'InstallLocation', RawPath) then
  begin
    RawPath := NormalizeInstallDir(RawPath);
    if RawPath <> '' then
    begin
      InstallDir := RawPath;
      Result := True;
      Exit;
    end;
  end;
  if RegQueryStringValue(RootKey, InstallerMetaSubkey, 'InstallLocation', RawPath) then
  begin
    RawPath := NormalizeInstallDir(RawPath);
    if RawPath <> '' then
    begin
      InstallDir := RawPath;
      Result := True;
      Exit;
    end;
  end;
end;

function IsDriveRootPath(const CandidatePath: String): Boolean;
var
  S: String;
  Drive: String;
begin
  S := Trim(CandidatePath);
  Drive := ExtractFileDrive(S);
  Result := (Length(Drive) = 2) and (CompareText(AddBackslash(S), Drive + '\') = 0);
end;

procedure InitializeWizard;
var
  Candidate: String;
  OtherHive: Integer;
  HasPreviousInno: Boolean;
  ExplicitDir: Boolean;
begin
  DetectedExistingDir := '';
  ExplicitDir := HasExplicitDirParam;
  HasPreviousInno := RegKeyExists(HKEY_AUTO, InnoUninstallSubkey);

  if HasPreviousInno then
  begin
    if not ExplicitDir then
      DetectedExistingDir := NormalizeInstallDir(WizardForm.DirEdit.Text);
  end
  else if not ExplicitDir then
  begin
    if QueryRecordedInstallLocation(HKEY_AUTO, Candidate) then
    begin
      WizardForm.DirEdit.Text := Candidate;
      DetectedExistingDir := Candidate;
    end
    else
    begin
      if IsAdminInstallMode then
        OtherHive := HKEY_CURRENT_USER
      else
        OtherHive := HKEY_LOCAL_MACHINE;

      if QueryRecordedInstallLocation(OtherHive, Candidate) and
         IsPathCompatibleWithCurrentMode(Candidate) then
      begin
        WizardForm.DirEdit.Text := Candidate;
        DetectedExistingDir := Candidate;
      end;
    end;
  end;

  if (DetectedExistingDir <> '') and (not ExplicitDir) then
  begin
    PreviousDirNoticeLabel := TNewStaticText.Create(WizardForm);
    PreviousDirNoticeLabel.Parent := WizardForm.SelectDirPage;
    PreviousDirNoticeLabel.Left := WizardForm.DirEdit.Left;
    PreviousDirNoticeLabel.Top := WizardForm.DirEdit.Top + WizardForm.DirEdit.Height + ScaleY(12);
    PreviousDirNoticeLabel.Width := WizardForm.DirBrowseButton.Left + WizardForm.DirBrowseButton.Width - WizardForm.DirEdit.Left;
    PreviousDirNoticeLabel.WordWrap := True;
    PreviousDirNoticeLabel.AutoSize := True;
    PreviousDirNoticeLabel.Caption := '已检测到本机已有安装，已自动为您选好原安装位置：' + DetectedExistingDir;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  CurrentDir: String;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    CurrentDir := Trim(WizardForm.DirEdit.Text);
    if IsDriveRootPath(CurrentDir) then
      WizardForm.DirEdit.Text := AddBackslash(CurrentDir) + 'OcPlayer';
  end;
end;

procedure TryUninstallLegacyMsiInHive(const RootKey: Integer);
var
  Subkeys: TArrayOfString;
  I: Integer;
  SubkeyName: String;
  FullKey: String;
  DisplayName: String;
  Publisher: String;
  WinInstaller: Cardinal;
  ResultCode: Integer;
begin
  if not RegGetSubkeyNames(RootKey, UninstallRootSubkey, Subkeys) then
    Exit;

  for I := 0 to GetArrayLength(Subkeys) - 1 do
  begin
    SubkeyName := Subkeys[I];
    if (Length(SubkeyName) = 38) and (SubkeyName[1] = '{') and (SubkeyName[38] = '}') then
    begin
      FullKey := UninstallRootSubkey + '\' + SubkeyName;
      if RegQueryDWordValue(RootKey, FullKey, 'WindowsInstaller', WinInstaller) and
         (WinInstaller = 1) and
         RegQueryStringValue(RootKey, FullKey, 'DisplayName', DisplayName) and
         (CompareText(Trim(DisplayName), 'OcPlayer') = 0) and
         RegQueryStringValue(RootKey, FullKey, 'Publisher', Publisher) and
         (CompareText(Trim(Publisher), 'OcPlayer') = 0) then
      begin
        Log('Detected legacy OcPlayer MSI ' + SubkeyName + '; attempting silent removal before Inno Setup install.');
        if Exec(ExpandConstant('{sys}\msiexec.exe'), '/x ' + SubkeyName + ' /qn /norestart', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
          Log('Legacy MSI removal finished with exit code ' + IntToStr(ResultCode))
        else
          Log('Failed to invoke msiexec.exe for legacy MSI ' + SubkeyName);
      end;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    TryUninstallLegacyMsiInHive(HKEY_CURRENT_USER);
    if IsAdminInstallMode then
      TryUninstallLegacyMsiInHive(HKEY_LOCAL_MACHINE);
  end;
end;
