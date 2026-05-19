param(
  [switch]$SkipFlutterBuild,
  # Publish the release to GitHub (gh release create). Off by default because
  # publishing is irreversible and visible to every user — opt in explicitly.
  [switch]$PublishRelease
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
$installerScript = Join-Path $repoRoot 'installer\entropy_vpn.iss'
$releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
$releaseExe = Join-Path $releaseDir 'entropy_vpn.exe'

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

# Version baking notice. The same `$appVersion` becomes:
#   - the gh tag (`v$appVersion`)
#   - the installer filename (EntropyVPN-Setup-$appVersion.exe)
#   - the manifest's `version` field (the service's source of truth)
#   - the bundled pubspec the running .exe will report
# An IDE Ctrl+Z that silently reverts pubspec right before this runs has
# bitten us before, so print it loud.
Write-Host ''
Write-Host "===> Building release for version: $appVersion" -ForegroundColor Cyan
Write-Host "     (this is read from pubspec.yaml right now; everything"
Write-Host "      downstream — gh tag, installer name, manifest.version,"
Write-Host "      bundled app version — comes from this single number.)"
Write-Host ''

if (-not $SkipFlutterBuild) {
  & 'C:\flutter\bin\flutter.bat' build windows
  if ($LASTEXITCODE -ne 0) {
    throw "flutter build windows failed with exit code $LASTEXITCODE"
  }
}

if (!(Test-Path $releaseExe)) {
  throw "Windows release build not found at $releaseExe"
}

# --- In-app update manifest -------------------------------------------------
# Generate the manifest + blobs.pack. build_release_manifest.ps1 also drops a
# copy of manifest.json next to the build output so the installer ships it.
$manifestOutputDir = Join-Path $repoRoot "build\release\$appVersion"
$manifestPath = Join-Path $manifestOutputDir 'manifest.json'
$packPath = Join-Path $manifestOutputDir 'blobs.pack'

Write-Host 'Generating release manifest...'
# Intentionally no -Version override: build_release_manifest.ps1 reads
# pubspec.yaml directly, the same way we just did above for $appVersion. One
# source of truth, no chance of an override drifting from pubspec.
& (Join-Path $PSScriptRoot 'build_release_manifest.ps1') -ReleaseDir $releaseDir -OutputDir $manifestOutputDir
if ($LASTEXITCODE -ne 0) {
  throw "build_release_manifest.ps1 failed with exit code $LASTEXITCODE"
}

# --- Installer --------------------------------------------------------------
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
$installerExe = Join-Path $outputDir "EntropyVPN-Setup-$appVersion.exe"
Write-Host "Installer built in: $outputDir"

# --- Publish ----------------------------------------------------------------
if ($PublishRelease) {
  $assets = @($installerExe, $manifestPath, $packPath)
  Write-Host "Publishing v$appVersion to GitHub with $($assets.Count) assets..."
  & gh release create "v$appVersion" --title "v$appVersion" @assets
  if ($LASTEXITCODE -ne 0) {
    throw "gh release create failed with exit code $LASTEXITCODE"
  }
  Write-Host "Published release v$appVersion."
} else {
  Write-Host ''
  Write-Host 'Release NOT published. To publish, re-run with -PublishRelease, or run:'
  Write-Host "  gh release create v$appVersion `"$installerExe`" `"$manifestPath`" `"$packPath`""
}
