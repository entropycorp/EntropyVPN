#define MyAppName "EntropyVPN"
#define MyAppExeName "entropy_vpn.exe"
#define MyAppPublisher "EntropyVPN"

#ifndef MyAppVersion
  #define MyAppVersion "1.2.0"
#endif

#ifndef MySourceRoot
  #define MySourceRoot ".."
#endif

#define MyReleaseDir AddBackslash(MySourceRoot) + "build\windows\x64\runner\Release"
#define MyOutputDir AddBackslash(MySourceRoot) + "build\installer"
#define MyIconFile AddBackslash(MySourceRoot) + "windows\runner\resources\app_icon.ico"

#ifnexist MyReleaseDir + "\" + MyAppExeName
  #error "Windows release build not found. Run `flutter build windows` first."
#endif

[Setup]
AppId={{7F29C2A3-6B6C-42D1-8C5E-5B6D8497AC7C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#MyOutputDir}
OutputBaseFilename=EntropyVPN-Setup-{#MyAppVersion}
SetupIconFile={#MyIconFile}
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
PrivilegesRequired=lowest
UsePreviousAppDir=yes
UsePreviousGroup=yes
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Installer
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MyReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb,*.lib,*.exp,*.ilk,entropy_vpn_icon_preview.png"

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
