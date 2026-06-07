<#
.SYNOPSIS
  Build BOTH platform releases (Windows + macOS) for Hype Raiders into one timestamped
  folder so a whole build is kept together and previous builds survive for rollback.

  Layout:  export/v<version>/<yyyy-MM-dd_HH-mm-ss>/windows/   (HypeRaiders.exe + zip)
           export/v<version>/<yyyy-MM-dd_HH-mm-ss>/mac/       (mac zip + README)

  A SINGLE timestamp is generated here and passed to both export scripts, so the Windows
  and macOS artifacts of the same build always share one dated folder. Older builds are
  never overwritten — to roll back, just grab the exe/zip from an earlier timestamp folder.

.EXAMPLE
  pwsh tools/build/export_all.ps1
  pwsh tools/build/export_all.ps1 -Version 0.3.0
#>
param(
    [string]$Godot = "C:\Users\illya\Desktop\godot\Godot_v4.6.3-stable_win64_console.exe",
    [string]$Version = "",
    # Skip the post-build "does the exe reach the menu" sanity check.
    [switch]$NoAliveCheck
)

$ErrorActionPreference = "Stop"
$ScriptDir  = $PSScriptRoot
$ProjectDir = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
if ([string]::IsNullOrWhiteSpace($Version)) {
    $verFile = Join-Path $ProjectDir "VERSION"
    if (Test-Path $verFile) { $Version = (Get-Content $verFile -Raw).Trim() } else { $Version = "0.0.0" }
}

# ONE shared stamp for this build → both platforms land in the same dated folder.
$Stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$BuildDir = Join-Path $ProjectDir "export\v$Version\$Stamp"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Hype Raiders — building BOTH platforms" -ForegroundColor Cyan
Write-Host "  Version : $Version"
Write-Host "  Stamp   : $Stamp"
Write-Host "  Output  : export/v$Version/$Stamp/{windows,mac}/"
Write-Host "==================================================================" -ForegroundColor Cyan

& (Join-Path $ScriptDir "export_windows.ps1") -Godot $Godot -Version $Version -Stamp $Stamp
& (Join-Path $ScriptDir "export_macos.ps1")   -Godot $Godot -Version $Version -Stamp $Stamp

# --- Post-build sanity: launch the exported exe briefly; it must reach the menu ---
if (-not $NoAliveCheck) {
    $exe = Join-Path $BuildDir "windows\HypeRaiders.exe"
    if (Test-Path $exe) {
        Write-Host "`n-- Alive-check: launching the exported exe --" -ForegroundColor Yellow
        $p = Start-Process -FilePath $exe -PassThru
        Start-Sleep -Seconds 9
        if ($p.HasExited) {
            Write-Host "   WARNING: exe exited early (code $($p.ExitCode)) — it may be crashing on boot." -ForegroundColor Red
        } else {
            Write-Host "   OK — exe still running after 9s (reached the menu)." -ForegroundColor Green
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host "  BOTH BUILDS DONE" -ForegroundColor Green
Write-Host "  $BuildDir" -ForegroundColor Green
Write-Host "  windows\HypeRaiders-v$Version-win64.zip   mac\HypeRaiders-v$Version-mac.zip"
Write-Host "  (older timestamp folders under export/v$Version/ are kept for rollback)"
Write-Host "==================================================================" -ForegroundColor Cyan
