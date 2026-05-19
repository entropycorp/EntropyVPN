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

; Auto-regenerate the manifest from pubspec.yaml before we read it. This is
; what `tools\build_installer.ps1` does for you; doing it inline here means
; a bare `iscc installer\entropy_vpn.iss` is self-contained — no separate
; script to remember. Fast (a SHA-256 walk over the Release dir, a few
; seconds on SSD). If powershell isn't available or the script errors, the
; mismatch check further down still fires as a safety net.
#define ManifestRegenScript AddBackslash(MySourceRoot) + "tools\build_release_manifest.ps1"
#if !FileExists(ManifestRegenScript)
  #error "tools\build_release_manifest.ps1 not found; can't auto-regenerate the manifest."
#endif
; Args: filename, params, workdir, ShowCmd (0=SW_HIDE), Wait (2=until terminated).
; Inno's preprocessor doesn't expose the named constants, so raw ints.
#expr Exec("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File """ + ManifestRegenScript + """", AddBackslash(MySourceRoot), 0, 2)

; Sanity-check the regen produced a manifest.json with a version that
; matches pubspec — catches the case where the regen silently failed
; (powershell missing, pubspec malformed, etc.).
#define ManifestPath MyReleaseDir + "\manifest.json"
#if !FileExists(ManifestPath)
  #error "manifest.json not found in release dir. Run `tools\build_installer.ps1` (or `tools\build_release_manifest.ps1`) before invoking Inno Setup."
#endif

#define public ManifestVersion ""
#define public ManifestHandle FileOpen(ManifestPath)

#sub ReadManifestLine
  #define public ManifestLineRaw FileRead(ManifestHandle)
  #define public ManifestLine Trim(ManifestLineRaw)
  #if Pos("""version""", ManifestLine) > 0
    #define public AfterColon Copy(ManifestLine, Pos(":", ManifestLine) + 1, Len(ManifestLine))
    #define public Q1 Pos("""", AfterColon)
    #if Q1 > 0
      #define public AfterQ1 Copy(AfterColon, Q1 + 1, Len(AfterColon))
      #define public Q2 Pos("""", AfterQ1)
      #if Q2 > 0
        #if Len(ManifestVersion) == 0
          #define public ManifestVersion Copy(AfterQ1, 1, Q2 - 1)
        #endif
      #endif
    #endif
  #endif
#endsub

#define m 0
#for {m = 0; m < 50; m++} ReadManifestLine
#undef m

#expr FileClose(ManifestHandle)
#undef ManifestHandle

#if Len(ManifestVersion) == 0
  #error "Could not read manifest.json's version field. Regenerate via `tools\build_release_manifest.ps1`."
#endif

#if ManifestVersion != MyAppVersion
  ; Inno's #error directive prints its argument as LITERAL TEXT — it does
  ; not evaluate string expressions or #define names. So we can't embed the
  ; mismatched version numbers; the message has to be self-explanatory.
  #error STALE MANIFEST: pubspec.yaml and build\windows\x64\runner\Release\manifest.json disagree on the release version. Run `powershell -ExecutionPolicy Bypass -File tools\build_release_manifest.ps1` (it reads pubspec, regenerates manifest.json + blobs.pack), then re-run this compile. Or use `tools\build_installer.ps1` to do the full pipeline in one shot.
#endif

; Build the [Files] exclude list from the single shared source of truth so the
; installer and the in-app update manifest never drift apart.
#define ExcludeGlobsPath AddBackslash(MySourceRoot) + "tools\release_exclude_globs.txt"
#if !FileExists(ExcludeGlobsPath)
  #error "tools/release_exclude_globs.txt not found; expected at " + ExcludeGlobsPath
#endif

#define public ReleaseExcludes ""
#define public ExcludeHandle FileOpen(ExcludeGlobsPath)

#sub ReadExcludeLine
  #define public ExcludeLineRaw FileRead(ExcludeHandle)
  #define public ExcludeLine Trim(ExcludeLineRaw)
  #if (Len(ExcludeLine) > 0) && (Pos("#", ExcludeLine) != 1)
    #if Len(ReleaseExcludes) == 0
      #define public ReleaseExcludes ExcludeLine
    #else
      #define public ReleaseExcludes ReleaseExcludes + "," + ExcludeLine
    #endif
  #endif
#endsub

#define k 0
#for {k = 0; k < 200; k++} ReadExcludeLine
#undef k

#expr FileClose(ExcludeHandle)
#undef ExcludeHandle

#if Len(ReleaseExcludes) == 0
  #error "release_exclude_globs.txt produced an empty exclude list"
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
Source: "{#MyReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "{#ReleaseExcludes}"

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
