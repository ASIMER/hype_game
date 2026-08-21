# Fetch the 2K ambientCG (CC0) ground PBR sets for the terrain splat + the gravel
# POI-apron layer. Downloads into asset-research/textures/<Id>/ (gitignored scratch),
# then the chosen maps are copied into assets/textures/ground/ RENAMED to the
# existing filenames so every .import sidecar + shader path survives untouched.
#
# Usage: pwsh tools/art/fetch_ground_textures.ps1
# Idempotent: skips a set whose zip already exists in the scratch dir.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scratch = Join-Path $root "asset-research\textures"
$dst = Join-Path $root "assets\textures\ground"
New-Item -ItemType Directory -Force $scratch | Out-Null

$sets = @("Ground003", "Ground054", "Rock029", "Gravel022")
foreach ($id in $sets) {
    $dir = Join-Path $scratch $id
    $zip = Join-Path $scratch "$id`_2K-JPG.zip"
    if (-not (Test-Path $zip)) {
        $url = "https://ambientcg.com/get?file=$id`_2K-JPG.zip"
        Write-Host "fetching $url"
        Invoke-WebRequest -Uri $url -OutFile $zip -UserAgent "HypeRaiders-asset-fetch"
        if ((Get-Item $zip).Length -lt 100000) { throw "suspiciously small download: $id" }
    }
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    Expand-Archive -Path $zip -DestinationPath $dir
    Write-Host "  unpacked -> $dir"
}

# Copy + RENAME into the live names the shader/material already references.
$map = @{
    "Ground003\Ground003_2K-JPG_Color.jpg"     = "Ground003_Color.jpg"
    "Ground003\Ground003_2K-JPG_NormalGL.jpg"  = "Ground003_NormalGL.jpg"
    "Ground003\Ground003_2K-JPG_Roughness.jpg" = "Ground003_Roughness.jpg"
    "Ground054\Ground054_2K-JPG_Color.jpg"     = "Ground054_Color.jpg"
    "Ground054\Ground054_2K-JPG_NormalGL.jpg"  = "Ground054_NormalGL.jpg"
    "Ground054\Ground054_2K-JPG_Roughness.jpg" = "Ground054_Roughness.jpg"
    "Rock029\Rock029_2K-JPG_Color.jpg"         = "Rock029_Color.jpg"
    "Rock029\Rock029_2K-JPG_NormalGL.jpg"      = "Rock029_NormalGL.jpg"
    "Rock029\Rock029_2K-JPG_Roughness.jpg"     = "Rock029_Roughness.jpg"
    "Gravel022\Gravel022_2K-JPG_Color.jpg"     = "Gravel022_Color.jpg"
    "Gravel022\Gravel022_2K-JPG_NormalGL.jpg"  = "Gravel022_NormalGL.jpg"
    "Gravel022\Gravel022_2K-JPG_Roughness.jpg" = "Gravel022_Roughness.jpg"
}
foreach ($k in $map.Keys) {
    $src = Join-Path $scratch $k
    if (-not (Test-Path $src)) { throw "missing expected map: $src" }
    Copy-Item $src (Join-Path $dst $map[$k]) -Force
    Write-Host "  -> assets/textures/ground/$($map[$k])"
}
Write-Host "DONE. Run the Godot --import to (re)generate sidecars for new files."
