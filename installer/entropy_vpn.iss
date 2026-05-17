#define MyAppName "EntropyVPN"
#define MyAppExeName "entropy_vpn.exe"
#define MyAppPublisher "EntropyVPN"

#ifndef MySourceRoot
  #define MySourceRoot ".."
#endif

#ifndef MyAppVersion
  #define PubspecPath AddBackslash(MySourceRoot) + "pubspec.yaml"
  #if !FileExists(PubspecPath)
    #error "pubspec.yaml not found; expected at " + PubspecPath
  #endif

  #define ExtractedVersion ""
  #define PubspecHandle FileOpen(PubspecPath)

  #sub ReadPubspecLine
    #define public cur FileRead(PubspecHandle)
    #if Pos("version:", cur) == 1
      #define public raw Trim(Copy(cur, 9, Len(cur) - 8))
      #if Pos("+", raw) > 0
        #define public raw Copy(raw, 1, Pos("+", raw) - 1)
      #endif
      #if Len(ExtractedVersion) == 0
        #define public ExtractedVersion raw
      #endif
    #endif
  #endsub

  #define i 0
  #for {i = 0; i < 500; i++} ReadPubspecLine
  #undef i

  #expr FileClose(PubspecHandle)
  #undef PubspecHandle

  #if Len(ExtractedVersion) == 0
    #error "Could not extract version from pubspec.yaml"
  #endif

  #define MyAppVersion ExtractedVersion
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
DefaultDirName={autopf}\{#MyAppName}
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
PrivilegesRequired=admin
UsePreviousAppDir=no
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
Filename: "{sys}\sc.exe"; Parameters: "stop EntropyVPNService"; Flags: runhidden waituntilterminated
Filename: "{sys}\sc.exe"; Parameters: "delete EntropyVPNService"; Flags: runhidden waituntilterminated
Filename: "{sys}\sc.exe"; Parameters: "create EntropyVPNService binPath= ""{app}\entropy_vpn_service.exe service"" start= demand DisplayName= ""EntropyVPN Service"""; Flags: runhidden waituntilterminated
Filename: "{sys}\sc.exe"; Parameters: "description EntropyVPNService ""Provides privileged Windows TUN mode support for EntropyVPN."""; Flags: runhidden waituntilterminated
Filename: "{sys}\sc.exe"; Parameters: "sdset EntropyVPNService D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPWPDTLOCRRC;;;AU)"; Flags: runhidden waituntilterminated
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\sc.exe"; Parameters: "stop EntropyVPNService"; Flags: runhidden waituntilterminated; RunOnceId: "EntropyVPNServiceStop"
Filename: "{sys}\sc.exe"; Parameters: "delete EntropyVPNService"; Flags: runhidden waituntilterminated; RunOnceId: "EntropyVPNServiceDelete"
