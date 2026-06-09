# fetch_real_audio.ps1 — download the REAL (CC0) audio that replaces the worst
# procedural sounds (laser gunshots + the synthetic background drone/pad).
#
# Everything pulled here is CC0 / public-domain (no attribution required), sourced
# from OpenGameArt. The remaining minor SFX (UI clicks, extract beeps, jingles,
# footsteps, heartbeat, weapon_switch) are STILL produced by tools/audio/gen_audio.py
# — only the gunshots + the two looping beds are replaced with recordings here.
#
# Re-run any time to re-fetch the asset set. Idempotent: re-downloads + overwrites.
# Catalog + licenses: docs/ASSETS.md (Audio section).

$ErrorActionPreference = "Stop"
$AudioDir = Join-Path $PSScriptRoot "..\..\assets\audio"
$Tmp = Join-Path $PSScriptRoot "..\..\asset-research\audio"
New-Item -ItemType Directory -Force -Path $AudioDir, $Tmp | Out-Null

function Fetch($url, $out) {
    Write-Host "  -> $out"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 120
}

Write-Host "== Gunshots: 'Gunshot Sounds' (CC0) — CZ-52 pistol / Mosin rifle / SKS / shotgun =="
# https://opengameart.org/content/gunshot-sounds  (CC0)
$gunsZip = Join-Path $Tmp "guns.zip"
Fetch "https://opengameart.org/sites/default/files/sounds.zip" $gunsZip
$gunsOut = Join-Path $Tmp "guns"
Expand-Archive -Path $gunsZip -DestinationPath $gunsOut -Force
$src = Join-Path $gunsOut "sounds"
# Map the four recorded firearms onto the game's five weapon classes (SMG reuses
# the snappy pistol crack, pitched up in AudioManager.SHOT_CLASS).
Copy-Item (Join-Path $src "cz.wav")     (Join-Path $AudioDir "shot_pistol.wav")  -Force
Copy-Item (Join-Path $src "sks.wav")    (Join-Path $AudioDir "shot_rifle.wav")   -Force
Copy-Item (Join-Path $src "cz.wav")     (Join-Path $AudioDir "shot_smg.wav")     -Force
Copy-Item (Join-Path $src "shotty.wav") (Join-Path $AudioDir "shot_shotgun.wav") -Force
Copy-Item (Join-Path $src "mosin.wav")  (Join-Path $AudioDir "shot_dmr.wav")     -Force
# The recordings are long multi-shot takes — isolate a single crack from each.
Write-Host "  trimming to single shots..."
python (Join-Path $PSScriptRoot "trim_shots.py")

Write-Host "== Ambience bed: 'Loopable Dungeon Ambience' (CC0) — low wind loop =="
# https://opengameart.org/content/loopable-dungeon-ambience  (CC0)
Fetch "https://opengameart.org/sites/default/files/dungeon_ambient_1_0.ogg" (Join-Path $AudioDir "ambient.ogg")

Write-Host "== Music bed: 'Dark Shrine Loop' by qubodup (CC0) — tense dark ambient =="
# https://opengameart.org/content/dark-shrine-loop  (CC0)
Fetch "https://opengameart.org/sites/default/files/qubodup-yd-DarkShrineLoop-OpenGameArt.ogg" (Join-Path $AudioDir "music.ogg")

Write-Host "== DONE — real CC0 audio placed in assets/audio/ =="
