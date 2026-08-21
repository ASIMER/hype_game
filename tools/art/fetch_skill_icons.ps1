# fetch_skill_icons.ps1 — download CC BY 3.0 ability icons (game-icons.net) for the Mutant-Harvest
# skill hotbar. Each game-icons SVG is 512x512 with a BLACK background path + a WHITE icon path; we
# strip the background so only the white icon remains (transparent), which Godot imports as a
# texture the hotbar tints per-skill (signature colour). For each skill we try an ordered list of
# candidate slugs and keep the FIRST that returns HTTP 200. Re-runnable. Attribution -> docs/ASSETS.md.

$ErrorActionPreference = "Stop"
$OutDir = Join-Path $PSScriptRoot "..\..\assets\ui\icons\skills"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Base = "https://raw.githubusercontent.com/game-icons/icons/master"

# skill_id -> ordered candidate "author/name" slugs (first that exists wins).
$Icons = [ordered]@{
  "leap"       = @("lorc/jump-across", "delapouite/leapfrog", "lorc/wingfoot", "lorc/run")
  "slam"       = @("lorc/falling-rocks", "lorc/ground-slam", "lorc/stomp", "lorc/war-axe")
  "blink"      = @("lorc/teleport", "delapouite/portal", "lorc/sparkle", "lorc/sprint")
  # MOBA rework: mortar is now METEOR — a falling burning rock, not a tube.
  "mortar"     = @("lorc/meteor-impact", "lorc/burning-meteor", "lorc/missile-mortar", "lorc/grenade")
  "shield"     = @("sbed/round-shield", "lorc/checked-shield", "delapouite/shield", "lorc/shield-reflect")
  "ram"        = @("lorc/charging-bull", "lorc/horned-helm", "delapouite/horn-internal", "lorc/bull-horns")
  "chainshock" = @("lorc/chain-lightning", "lorc/lightning-arc", "sbed/electric", "lorc/power-lightning")
  "bite"       = @("lorc/fangs", "lorc/sharp-smile", "lorc/spiked-tail", "lorc/saber-tooth")
  # MOBA rework: whirlwind is now STORM — the CM frost-field orb over a tornado.
  "whirlwind"  = @("lorc/frozen-orb", "lorc/ice-bolt", "lorc/tornado", "lorc/cyclone")
  "recon"      = @("lorc/eye-target", "delapouite/semi-closed-eye", "lorc/all-seeing-eye", "lorc/eyeball")
}

# Remove the opaque background rect path so the icon is transparent (white-on-nothing).
function Strip-Bg([string]$svg) {
  return ($svg -replace '<path d="M0 0h512v512H0z"\s*/>', '')
}

$resolved = @{}
foreach ($skill in $Icons.Keys) {
  $done = $false
  foreach ($slug in $Icons[$skill]) {
    $url = "$Base/$slug.svg"
    try {
      $svg = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30).Content
    } catch { continue }
    if ($svg -notmatch "<svg") { continue }
    $svg = Strip-Bg $svg
    $out = Join-Path $OutDir "$skill.svg"
    [System.IO.File]::WriteAllText($out, $svg)
    $resolved[$skill] = $slug
    $done = $true
    break
  }
  if (-not $done) { Write-Host "WARN: no icon resolved for '$skill'" -ForegroundColor Yellow }
}

Write-Host "`n== Skill icons (CC BY 3.0, game-icons.net) — add to docs/ASSETS.md ==" -ForegroundColor Cyan
foreach ($skill in $resolved.Keys) {
  Write-Host ("  {0,-12} -> {1}" -f $skill, $resolved[$skill])
}
