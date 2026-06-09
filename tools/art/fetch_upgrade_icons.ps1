# fetch_upgrade_icons.ps1 — download CC BY 3.0 ability icons (game-icons.net) for the Hub credit
# upgrades (MetaProgression.UPGRADES). Same processing as fetch_power_icons.ps1: each game-icons SVG
# is 512x512 with a BLACK background path + a WHITE icon path; we strip the background so only the
# white icon remains (transparent), which Godot imports + we tint per-upgrade. For each upgrade we try
# an ordered list of candidate slugs and keep the FIRST that returns HTTP 200. Attribution: docs/ASSETS.md.

$ErrorActionPreference = "Stop"
$OutDir = Join-Path $PSScriptRoot "..\..\assets\ui\icons\upgrades"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Base = "https://raw.githubusercontent.com/game-icons/icons/master"

$Icons = [ordered]@{
  "player_health" = @("lorc/glass-heart", "lorc/heart-bottle", "delapouite/health-potion")
  "reload_speed"  = @("delapouite/machine-gun-magazine", "lorc/quick-slash", "lorc/clockwork")
  "stamina"       = @("lorc/run", "delapouite/run", "delapouite/sprint")
  "weapon_damage" = @("lorc/bullets", "lorc/targeting", "delapouite/striking-arrows")
  "stash_capacity"= @("delapouite/backpack", "lorc/open-treasure-chest", "delapouite/box", "lorc/locked-chest")
}

function Strip-Bg([string]$svg) { return ($svg -replace '<path d="M0 0h512v512H0z"\s*/>', '') }

$resolved = @{}
foreach ($key in $Icons.Keys) {
  $done = $false
  foreach ($slug in $Icons[$key]) {
    try { $svg = (Invoke-WebRequest -Uri "$Base/$slug.svg" -UseBasicParsing -TimeoutSec 30).Content }
    catch { continue }
    if ($svg -notmatch "<svg") { continue }
    [System.IO.File]::WriteAllText((Join-Path $OutDir "$key.svg"), (Strip-Bg $svg))
    $resolved[$key] = $slug
    Write-Host ("  {0,-15} -> {1}" -f $key, $slug)
    $done = $true; break
  }
  if (-not $done) { Write-Warning "no icon resolved for $key" }
}
Write-Host "== DONE — upgrade icons in assets/ui/icons/upgrades/ =="
foreach ($k in $resolved.Keys) { Write-Host ("  {0}: game-icons.net {1} (CC BY 3.0)" -f $k, $resolved[$k]) }
