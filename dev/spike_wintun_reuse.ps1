#requires -RunAsAdministrator
<#
  spike_wintun_reuse.ps1

  Verification spike: does xray.exe (sing-tun) REUSE a pre-existing wintun
  adapter named "EntropyVPN TUN", or does it CREATE A DUPLICATE?

  This is the make-or-break question for the pre-create startup optimization.

  Safe to run: xray is started with a minimal TUN config that has NO
  autoRoute, so it creates/opens the adapter but installs no routes and
  cannot hijack your internet. The adapter we create is bare (no IP/routes).
  All resources are cleaned up at the end (and on exit, since a wintun
  adapter is removed when the creating process dies).

  Run from an ELEVATED PowerShell prompt.
#>

$ErrorActionPreference = 'Stop'

$CoresDir    = 'C:\Program Files\EntropyVPN\cores'
$WintunDll   = Join-Path $CoresDir 'wintun.dll'
$XrayExe     = Join-Path $CoresDir 'xray.exe'
$AdapterName = 'EntropyVPN TUN'

foreach ($p in @($WintunDll, $XrayExe)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Required file not found: $p" }
}

$src = @'
using System;
using System.Runtime.InteropServices;
public static class Spike {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr LoadLibrary(string path);

    [DllImport("wintun.dll", EntryPoint="WintunCreateAdapter", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr WintunCreateAdapter(string name, string tunnelType, IntPtr requestedGuid);

    [DllImport("wintun.dll", EntryPoint="WintunCloseAdapter", SetLastError=true)]
    public static extern void WintunCloseAdapter(IntPtr adapter);

    [DllImport("wintun.dll", EntryPoint="WintunOpenAdapter", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr WintunOpenAdapter(string name);
}
'@
Add-Type -TypeDefinition $src

# Load wintun.dll by full path so the bare-name DllImports resolve to it.
if ([Spike]::LoadLibrary($WintunDll) -eq [IntPtr]::Zero) {
    throw "LoadLibrary failed for $WintunDll (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
}

function Get-WintunAdapters {
    Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$AdapterName*" -or $_.InterfaceDescription -like '*Wintun*' } |
        Select-Object Name, InterfaceDescription, ifIndex, Status
}

function Count-OurAdapters {
    @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$AdapterName*" }).Count
}

Write-Host "=== wintun reuse spike ===" -ForegroundColor Cyan

$before = @(Get-WintunAdapters)
Write-Host "`n[before] wintun adapters present (any pre-existing ones - e.g. a live VPN - are fine):"
$before | Format-Table -AutoSize
$baselineIdx = @($before | ForEach-Object { $_.ifIndex })

$handle = [IntPtr]::Zero
$xray   = $null
try {
    Write-Host "Creating wintun adapter '$AdapterName' (tunnelType 'EntropyVPN') ..."
    $handle = [Spike]::WintunCreateAdapter($AdapterName, 'EntropyVPN', [IntPtr]::Zero)
    if ($handle -eq [IntPtr]::Zero) {
        throw "WintunCreateAdapter failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    Write-Host "  -> created, handle=$handle" -ForegroundColor Green
    Start-Sleep -Milliseconds 600

    # Identify OUR adapter by the ifIndex that did not exist in the baseline.
    $afterCreate = @(Get-WintunAdapters)
    $ours = $afterCreate | Where-Object { $baselineIdx -notcontains $_.ifIndex } | Select-Object -First 1
    if ($ours -eq $null) { throw "Could not locate the adapter we just created." }
    $ourIndex = $ours.ifIndex
    Write-Host "`n[after create] OUR adapter -> ifIndex=$ourIndex, status=$($ours.Status)"
    $afterCreate | Format-Table -AutoSize

    # Minimal xray TUN config: NO autoRoute -> creates the adapter, installs
    # nothing, cannot hijack routing.
    $cfg = Join-Path $env:TEMP 'spike_xray_tun.json'
    $cfgJson = @'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "tun-in", "protocol": "tun",
      "settings": { "name": "EntropyVPN TUN", "MTU": 1400, "userLevel": 0 } }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" } ]
}
'@
    [System.IO.File]::WriteAllText($cfg, $cfgJson, (New-Object System.Text.UTF8Encoding $false))

    $outLog = Join-Path $env:TEMP 'spike_xray.out.log'
    $errLog = Join-Path $env:TEMP 'spike_xray.err.log'
    Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

    Write-Host "`nStarting xray with a minimal TUN config ..."
    $xray = Start-Process -FilePath $XrayExe `
        -ArgumentList @('run', '-c', $cfg) `
        -WorkingDirectory $CoresDir `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
        -PassThru -WindowStyle Hidden

    Start-Sleep -Seconds 5

    # Identity-based check: did a NEW adapter appear (one whose ifIndex was
    # neither in the baseline nor our own)? That would be xray creating its own.
    $afterXray = @(Get-WintunAdapters)
    $oursNow   = $afterXray | Where-Object { $_.ifIndex -eq $ourIndex } | Select-Object -First 1
    $newOnes   = @($afterXray | Where-Object {
        $baselineIdx -notcontains $_.ifIndex -and $_.ifIndex -ne $ourIndex })
    Write-Host "`n[after xray] wintun adapters:"
    $afterXray | Format-Table -AutoSize

    if ($xray -ne $null -and -not $xray.HasExited) {
        Stop-Process -Id $xray.Id -Force
    }
    Start-Sleep -Milliseconds 400

    $xrayLog = ''
    foreach ($f in @($errLog, $outLog)) {
        if (Test-Path $f) { $xrayLog += (Get-Content -Raw -LiteralPath $f) }
    }
    Write-Host "`n--- xray output ---" -ForegroundColor DarkGray
    Write-Host $xrayLog
    Write-Host "-------------------" -ForegroundColor DarkGray

    $createdMsg   = [bool]($xrayLog -match 'Creating adapter')
    $matchMsg     = [bool]($xrayLog -match 'Failed to find matching adapter name')
    $ourStatusNow = if ($oursNow -ne $null) { $oursNow.Status } else { '(gone)' }

    Write-Host "`n=== VERDICT ===" -ForegroundColor Cyan
    Write-Host "our adapter ifIndex=$ourIndex status: created='$($ours.Status)' -> after xray='$ourStatusNow'"
    Write-Host "NEW adapters xray created (excl. ours + baseline) : $($newOnes.Count)"
    if ($newOnes.Count -gt 0) { $newOnes | Format-Table -AutoSize }
    Write-Host "xray logged 'Creating adapter'             : $createdMsg"
    Write-Host "xray logged 'Failed to find matching ...'  : $matchMsg"
    if ($newOnes.Count -eq 0 -and -not $createdMsg) {
        Write-Host "REUSED -> xray opened our existing adapter (no new adapter created)." -ForegroundColor Green
        Write-Host "          Pre-create optimization is VIABLE." -ForegroundColor Green
    } elseif ($newOnes.Count -ge 1 -or $createdMsg) {
        Write-Host "DUPLICATED -> xray created its own adapter. Pre-create needs a different tactic." -ForegroundColor Red
    } else {
        Write-Host "INCONCLUSIVE -> inspect the xray output above." -ForegroundColor Yellow
    }
}
finally {
    if ($xray -ne $null -and -not $xray.HasExited) {
        Stop-Process -Id $xray.Id -Force -ErrorAction SilentlyContinue
    }
    if ($handle -ne [IntPtr]::Zero) {
        Write-Host "`nCleaning up: closing our wintun adapter ..."
        [Spike]::WintunCloseAdapter($handle)
    }
    Write-Host "[remaining] adapters named '$AdapterName*': $(Count-OurAdapters)"
}
