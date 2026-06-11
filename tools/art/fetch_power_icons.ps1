# fetch_power_icons.ps1 — download CC BY 3.0 ability icons (game-icons.net) for the Power Cache
# buffs. Each game-icons SVG is a 512x512 with a BLACK background path + a WHITE icon path; we strip
# the background so only the white icon remains (transparent), which Godot imports as a texture we
# tint per-power. For each power we try an ordered list of candidate slugs and keep the FIRST that
# returns HTTP 200. Re-runnable. Attribution lives in docs/ASSETS.md (CC-BY requires it).

$ErrorActionPreference = "Stop"
$OutDir = Join-Path $PSScriptRoot "..\..\assets\ui\icons\powers"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Base = "https://raw.githubusercontent.com/game-icons/icons/master"

# power -> ordered candidate "author/name" slugs (first that exists wins).
$Icons = [ordered]@{
  "berserk"    = @("lorc/battle-axe", "lorc/sharp-axe", "lorc/axe-swing")
  "rapidfire"  = @("lorc/gatling-gun", "lorc/minigun", "delapouite/machine-gun-magazine", "lorc/heavy-bullets")
  "swift"      = @("lorc/wingfoot", "lorc/run", "delapouite/sprint", "lorc/boots")
  "overshield" = @("lorc/checked-shield", "sbed/round-shield", "lorc/shield-reflect", "delapouite/shield")
  "regen"      = @("lorc/health-increase", "delapouite/health-increase", "lorc/hearts", "sbed/health-increase", "lorc/heart-plus")
  "lifesteal"  = @("lorc/bleeding-heart", "lorc/vampire-dracula", "lorc/fangs", "lorc/drop", "sbed/blood")
  "juggernaut" = @("lorc/breastplate", "lorc/armor-vest", "delapouite/armor-upgrade", "sbed/armor-vest")
  "adrenaline" = @("lorc/energise", "lorc/lightning-arc", "lorc/power-lightning", "sbed/electric")
  "frenzy"     = @("lorc/star-swirl", "lorc/star-formation", "lorc/sun", "lorc/explosion-rays", "lorc/embrasure")
}

# Remove the opaque background rect path so the icon is transparent (white-on-nothing).
function Strip-Bg([string]$svg) {
  return ($svg -replace '<path d="M0 0h512v512H0z"\s*/>', '')
}

$resolved = @{}
foreach ($power in $Icons.Keys) {
  $done = $false
  foreach ($slug in $Icons[$power]) {
    $url = "$Base/$slug.svg"
    try {
      $svg = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30).Content
    } catch { continue }
    if ($svg -notmatch "<svg") { continue }
    $svg = Strip-Bg $svg
    $out = Join-Path $OutDir "$power.svg"
    [System.IO.File]::WriteAllText($out, $svg)
    $resolved[$power] = $slug
    Write-Host ("  {0,-11} -> {1}" -f $power, $slug)
    $done = $true
    break
  }
  if (-not $done) { Write-Warning "no icon resolved for $power" }
}
Write-Host "== DONE — power icons in assets/ui/icons/powers/ =="
Write-Host "Attribution (add to docs/ASSETS.md):"
foreach ($k in $resolved.Keys) { Write-Host ("  {0}: game-icons.net {1} (CC BY 3.0)" -f $k, $resolved[$k]) }
