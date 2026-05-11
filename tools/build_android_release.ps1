param(
  [switch]$SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
$flutterApkDir = Join-Path $repoRoot 'build\app\outputs\flutter-apk'
$gradleWrapper = Join-Path $repoRoot 'android\gradlew.bat'
$flutterCommand = (Get-Command flutter -ErrorAction SilentlyContinue).Source

if ($null -eq $flutterCommand) {
  $flutterCommand = 'C:\flutter\bin\flutter.bat'
}

if (!(Test-Path $flutterCommand)) {
  throw "flutter was not found at $flutterCommand"
}

if (!(Test-Path $pubspecPath)) {
  throw "pubspec.yaml not found at $pubspecPath"
}

$versionLine = Select-String -Path $pubspecPath -Pattern '^version:\s*([^\s]+)' | Select-Object -First 1
if ($null -eq $versionLine -or $versionLine.Matches.Count -eq 0) {
  throw 'Could not read app version from pubspec.yaml'
}

$appVersion = ($versionLine.Matches[0].Groups[1].Value -split '\+')[0]

function Stop-GradleDaemons {
  if (Test-Path -LiteralPath $gradleWrapper) {
    & $gradleWrapper --stop *> $null
  }
}

if (-not $SkipFlutterBuild) {
  Stop-GradleDaemons
  try {
    & $flutterCommand build apk --release --split-per-abi --target-platform android-arm,android-arm64
    if ($LASTEXITCODE -ne 0) {
      throw "flutter build apk failed with exit code $LASTEXITCODE"
    }
  } finally {
    Stop-GradleDaemons
  }
}

if (!(Test-Path $flutterApkDir)) {
  throw "Flutter APK output directory not found at $flutterApkDir"
}

$defaultReleaseArtifacts = @(
  'app-release.apk',
  'app-release.apk.sha1',
  'app-arm64-v8a-release.apk',
  'app-arm64-v8a-release.apk.sha1',
  'app-armeabi-v7a-release.apk',
  'app-armeabi-v7a-release.apk.sha1',
  'app-x86_64-release.apk',
  'app-x86_64-release.apk.sha1'
)

foreach ($artifact in $defaultReleaseArtifacts) {
  $artifactPath = Join-Path $flutterApkDir $artifact
  if (Test-Path -LiteralPath $artifactPath) {
    Remove-Item -LiteralPath $artifactPath -Force
  }
}

$releaseApks = @(
  "entropyvpn-$appVersion-arm64-v8a.apk",
  "entropyvpn-$appVersion-armeabi-v7a.apk"
)

$missingApks = @(
  foreach ($apk in $releaseApks) {
    $apkPath = Join-Path $flutterApkDir $apk
    if (!(Test-Path -LiteralPath $apkPath)) {
      $apk
    }
  }
)

if ($missingApks.Count -gt 0) {
  throw "Expected release APKs were not created: $($missingApks -join ', ')"
}

Write-Host "Release APKs:"
foreach ($apk in $releaseApks) {
  Write-Host " - $(Join-Path $flutterApkDir $apk)"
}
