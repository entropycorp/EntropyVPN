param(
  [switch]$SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
$installerScript = Join-Path $repoRoot 'installer\entropy_vpn.iss'
$releaseExe = Join-Path $repoRoot 'build\windows\x64\runner\Release\entropy_vpn.exe'

if (!(Test-Path $pubspecPath)) {
  throw "pubspec.yaml not found at $pubspecPath"
}

if (!(Test-Path $installerScript)) {
  throw "Installer script not found at $installerScript"
}

$versionLine = Select-String -Path $pubspecPath -Pattern '^version:\s*([^\s]+)' | Select-Object -First 1
if ($null -eq $versionLine -or $versionLine.Matches.Count -eq 0) {
  throw 'Could not read app version from pubspec.yaml'
}

$appVersion = ($versionLine.Matches[0].Groups[1].Value -split '\+')[0]

if (-not $SkipFlutterBuild) {
  & 'C:\flutter\bin\flutter.bat' build windows
  if ($LASTEXITCODE -ne 0) {
    throw "flutter build windows failed with exit code $LASTEXITCODE"
  }
}

if (!(Test-Path $releaseExe)) {
  throw "Windows release build not found at $releaseExe"
}

$isccCandidates = @(
  'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
  'C:\Program Files\Inno Setup 6\ISCC.exe'
)

$iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($null -eq $iscc) {
  throw 'ISCC.exe not found. Install Inno Setup 6 first: https://jrsoftware.org/isinfo.php'
}

& $iscc "/DMyAppVersion=$appVersion" "/DMySourceRoot=$repoRoot" $installerScript
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
}

$outputDir = Join-Path $repoRoot 'build\installer'
Write-Host "Installer built in: $outputDir"
