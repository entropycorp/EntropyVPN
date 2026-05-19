<#
.SYNOPSIS
  Generates the EntropyVPN in-app update manifest + pack file for a Windows
  release build.

.DESCRIPTION
  Walks the Flutter Windows Release directory, records SHA-256 + size for every
  shippable file, and emits:

    build/release/<version>/manifest.json   - the update manifest
    build/release/<version>/blobs.pack      - all unique file contents
                                              concatenated, deduplicated by
                                              SHA-256. The manifest records
                                              each file's byte offset into
                                              this pack so the updater can pull
                                              individual files with a single
                                              HTTP Range request.
    <ReleaseDir>/manifest.json              - a copy dropped next to the build
                                              output so the Inno Setup installer
                                              picks it up via its Release
                                              wildcard. (The installer does NOT
                                              ship blobs.pack; that's only used
                                              for over-the-air updates from
                                              GitHub Releases.)

  The set of excluded files is read from tools/release_exclude_globs.txt, the
  single source of truth shared with installer/entropy_vpn.iss.

.PARAMETER ReleaseDir
  Flutter Windows Release directory. Defaults to
  build/windows/x64/runner/Release.

.PARAMETER OutputDir
  Where to write manifest.json + blobs.pack. Defaults to
  build/release/<version>.

.NOTES
  There is no -Version override. The manifest's "version" field always comes
  from pubspec.yaml — it's the single source of truth for the gh tag, the
  installer filename, the bundled in-app version, and the manifest. A
  -Version override existed at one point and was removed because a stale or
  wrong override would silently produce an installer whose manifest disagreed
  with pubspec, which is exactly the bug the installer .iss now guards
  against. Bump pubspec instead.
#>
param(
  [string]$ReleaseDir,
  [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# These two files are never listed in a manifest: manifest.json would make the
# manifest reference itself, and installed_manifest.json is per-machine state
# written by the service.
$selfExcludedNames = @('manifest.json', 'installed_manifest.json')

function Read-AppVersion {
  $pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
  if (!(Test-Path $pubspecPath)) {
    throw "pubspec.yaml not found at $pubspecPath"
  }
  $versionLine = Select-String -Path $pubspecPath -Pattern '^version:\s*([^\s]+)' |
    Select-Object -First 1
  if ($null -eq $versionLine -or $versionLine.Matches.Count -eq 0) {
    throw 'Could not read app version from pubspec.yaml'
  }
  return ($versionLine.Matches[0].Groups[1].Value -split '\+')[0]
}

function ConvertTo-GlobRegex([string]$glob) {
  $escaped = [Regex]::Escape($glob)
  $escaped = $escaped -replace '\\\*', '.*'
  $escaped = $escaped -replace '\\\?', '.'
  return "^$escaped$"
}

function Get-ExcludeGlobs {
  $excludeFile = Join-Path $PSScriptRoot 'release_exclude_globs.txt'
  if (!(Test-Path $excludeFile)) {
    throw "Exclude glob list not found at $excludeFile"
  }
  $globs = @()
  foreach ($line in Get-Content -LiteralPath $excludeFile) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) {
      continue
    }
    $globs += [pscustomobject]@{
      HasSlash = $trimmed.Contains('/')
      Regex    = [Regex]::new((ConvertTo-GlobRegex $trimmed),
                              [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
  }
  return $globs
}

function Test-Excluded {
  param(
    [string]$RelativePath,
    [string]$BaseName,
    $Globs
  )
  foreach ($glob in $Globs) {
    $candidate = if ($glob.HasSlash) { $RelativePath } else { $BaseName }
    if ($glob.Regex.IsMatch($candidate)) {
      return $true
    }
  }
  return $false
}

$Version = Read-AppVersion

if (-not $ReleaseDir) {
  $ReleaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
}
if (!(Test-Path $ReleaseDir)) {
  throw "Release directory not found at $ReleaseDir. Run `flutter build windows` first."
}
$ReleaseDir = (Resolve-Path $ReleaseDir).Path

# Match the installer's guard: never publish a manifest for a release dir that
# doesn't contain the main executable.
$entryExe = Join-Path $ReleaseDir 'entropy_vpn.exe'
if (!(Test-Path -LiteralPath $entryExe)) {
  throw "Release directory $ReleaseDir is missing entropy_vpn.exe. Run `flutter build windows` first."
}

if (-not $OutputDir) {
  $OutputDir = Join-Path $repoRoot "build\release\$Version"
}

if (Test-Path $OutputDir) {
  Remove-Item -LiteralPath $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$packPath = Join-Path $OutputDir 'blobs.pack'
$excludeGlobs = Get-ExcludeGlobs

# List<object> avoids the O(n^2) cost of repeated `$files += ...`.
$files = [System.Collections.Generic.List[object]]::new()
$blobOffsets = @{}  # sha256 -> [int64] byte offset into blobs.pack
$seenPaths = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$releaseDirPrefix = $ReleaseDir.TrimEnd('\') + '\'

# Pack writer. FileShare::None blocks anything else from racing the build.
$packStream = [System.IO.File]::Open(
    $packPath,
    [System.IO.FileMode]::Create,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::None)

try {
  foreach ($item in Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File) {
    $fullPath = $item.FullName
    if (-not $fullPath.StartsWith($releaseDirPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      continue
    }
    $relativePath = $fullPath.Substring($releaseDirPrefix.Length) -replace '\\', '/'

    if ($selfExcludedNames -contains $item.Name) {
      continue
    }
    if (Test-Excluded -RelativePath $relativePath -BaseName $item.Name -Globs $excludeGlobs) {
      continue
    }

    if (-not $seenPaths.Add($relativePath)) {
      throw "Duplicate manifest path: $relativePath"
    }

    $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($blobOffsets.ContainsKey($hash)) {
      $offset = $blobOffsets[$hash]
    } else {
      $offset = [int64]$packStream.Position
      $src = [System.IO.File]::OpenRead($fullPath)
      try {
        $src.CopyTo($packStream)
      } finally {
        $src.Dispose()
      }
      $blobOffsets[$hash] = $offset
    }

    [void]$files.Add([ordered]@{
      path        = $relativePath
      size        = [int64]$item.Length
      sha256      = $hash
      pack_offset = $offset
    })
  }
}
finally {
  $packStream.Dispose()
}

# Sort entries by path using ordinal comparison so the manifest is
# byte-identical across machines/cultures (default Sort-Object is locale-aware
# and treats '-' as a "soft" separator, which produces noisy diffs).
$fileArray = $files.ToArray()
$pathArray = [string[]]($fileArray | ForEach-Object { $_.path })
[Array]::Sort($pathArray, $fileArray, [System.StringComparer]::Ordinal)
$files = $fileArray

$generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

$manifest = [ordered]@{
  schema       = 2
  version      = $Version
  generated_at = $generatedAt
  files        = @($files)
}

$manifestJson = $manifest | ConvertTo-Json -Depth 6
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$manifestPath = Join-Path $OutputDir 'manifest.json'
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, $utf8NoBom)

# Drop a copy next to the build output so the installer's Release wildcard
# ships it into the install directory.
[System.IO.File]::WriteAllText((Join-Path $ReleaseDir 'manifest.json'),
                               $manifestJson, $utf8NoBom)

$totalBytes = 0L
foreach ($entry in $files) {
  $totalBytes += [int64]$entry.size
}
$packSize = (Get-Item -LiteralPath $packPath).Length

# Sanity check: re-read what we just wrote, confirm it round-trips as JSON,
# every range fits inside the pack, and a spot-checked slice actually hashes to
# the sha256 we recorded. Catches silent corruption before the manifest reaches
# `gh release create`.
$roundTrip = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($roundTrip.schema -ne 2) {
  throw "Generated manifest has wrong schema: $($roundTrip.schema)"
}
if ($roundTrip.version -ne $Version) {
  throw "Generated manifest version mismatch: $($roundTrip.version) vs $Version"
}
if ($roundTrip.files.Count -ne $files.Count) {
  throw "Round-trip file count mismatch: $($roundTrip.files.Count) vs $($files.Count)"
}
foreach ($entry in $roundTrip.files) {
  $end = [int64]$entry.pack_offset + [int64]$entry.size
  if ($end -gt $packSize) {
    throw "Pack range for $($entry.path) ($($entry.pack_offset)+$($entry.size)) exceeds pack size $packSize."
  }
}

# Spot-check: pull the largest entry's slice out of the pack and confirm its
# sha256 matches. If concatenation got the offsets wrong, this catches it.
$largest = $roundTrip.files | Sort-Object -Property size -Descending | Select-Object -First 1
if ($null -ne $largest -and [int64]$largest.size -gt 0) {
  $reader = [System.IO.File]::OpenRead($packPath)
  try {
    [void]$reader.Seek([int64]$largest.pack_offset, [System.IO.SeekOrigin]::Begin)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $buffer = New-Object byte[] (1MB)
      $remaining = [int64]$largest.size
      while ($remaining -gt 0) {
        $want = [int]([Math]::Min([int64]$buffer.Length, $remaining))
        $read = $reader.Read($buffer, 0, $want)
        if ($read -le 0) {
          throw "Unexpected EOF while spot-checking $($largest.path)."
        }
        [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
        $remaining -= $read
      }
      [void]$sha.TransformFinalBlock($buffer, 0, 0)
      $actual = ([System.BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
      $sha.Dispose()
    }
  }
  finally {
    $reader.Dispose()
  }
  if ($actual -ne $largest.sha256) {
    throw "Spot-check failed for $($largest.path): pack slice hashes to $actual but manifest says $($largest.sha256)."
  }
}

Write-Host "Manifest written: $manifestPath"
Write-Host "Pack written    : $packPath"
Write-Host "  version       : $Version"
Write-Host "  files         : $($files.Count)"
Write-Host "  unique blobs  : $($blobOffsets.Count)"
Write-Host "  total bytes   : $totalBytes"
Write-Host "  pack bytes    : $packSize"
