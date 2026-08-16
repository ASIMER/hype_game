"""Fetch + bake the ambientCG (CC0) PBR sets used as REAL building-facade surfaces (D3.1).

Downloads into the gitignored ``asset-research/textures/`` scratch dir, then writes three
maps per family into ``assets/textures/facade/``.

WHY THE ALBEDO IS BAKED INSTEAD OF COPIED
-----------------------------------------
A photo albedo cannot simply replace the procedural one. Every building colour in
``procedural_buildings.mat_*`` was hand-balanced against the cold grade and the D1 relight,
and a real texture's mean brightness ranges from 0.03 (rust) to 0.66 (plaster) — dropping
them in raw would re-darken exactly what the relight pass fixed, unevenly, per material.

So the shipped albedo is not a colour map at all: it is a bounded **modulation** map with a
mean of 1.0, encoded at half scale. The material multiplies it by ``tint * ALBEDO_SCALE``,
so the average surface colour is EXACTLY the authored tint and the texture contributes only
the structure — brick courses, plank seams, concrete pores, rust blooming. Contrast and how
much of the photo's own colour survives are per-family knobs below.

The half-scale encode is what lets a modulation exceed 1.0 (mortar joints, bare metal
highlights) inside an 8-bit [0,1] file.

Normal maps ship as-is and are the single biggest upgrade here — noise normals cannot fake
grazing-angle relief.

Roughness maps are deliberately NOT shipped. Godot multiplies ``roughness_texture`` into the
``roughness`` scalar and clamps at 1.0, so a matte authored value (slabs sit at 0.94) cannot
be compensated back up after a mean-0.5 map halves it — every concrete surface would come out
wet-looking, undoing the relight tuning. Roughness variation instead stays on the grime mask
(see ``ProcMaterials.weathered``), which is bounded by construction.

Usage: python tools/art/fetch_facade_textures.py
Idempotent: skips a set whose zip is already in the scratch dir. Run the Godot --import
afterwards to generate the sidecars.
"""

from __future__ import annotations

import io
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SCRATCH = ROOT / "asset-research" / "textures"
DST = ROOT / "assets" / "textures" / "facade"

# The material multiplies by tint * ALBEDO_SCALE; keep in sync with ProcMaterials.
ALBEDO_SCALE = 2.0
MOD_LO, MOD_HI = 0.30, 1.85
JPEG_Q = 95

# family -> (ambientCG set id, contrast, chroma)
#   contrast: how much of the photo's luminance range survives (1.0 = all of it).
#   chroma:   how much of the photo's own hue survives on top of the authored tint.
#             stone is near zero on purpose — Rock022 is grey-green and the desert
#             ruins must read warm sandstone, so only its stratification is wanted.
FAMILIES: dict[str, tuple[str, float, float]] = {
    # Concrete016 and Plaster001 are smooth studio scans — at contrast 1.0 their modulation
    # spans barely ±0.1 and the wall reads as flat as before. Amplified past the photo's own
    # range on purpose: this is a modulation map, not a colour record.
    "concrete": ("Concrete016", 1.70, 0.25),
    "metal": ("MetalPlates013", 0.90, 0.35),
    "rust": ("Rust004", 0.95, 0.55),
    "plaster": ("Plaster001", 1.90, 0.20),
    "timber": ("Planks011", 0.95, 0.55),
    "stone": ("Rock022", 0.90, 0.10),
    "brick": ("Bricks023", 1.00, 0.55),
}


def download(set_id: str) -> Path:
    """Return the unpacked scratch dir for `set_id`, downloading the zip if needed."""
    zip_path = SCRATCH / f"{set_id}_1K-JPG.zip"
    out_dir = SCRATCH / set_id
    if not zip_path.exists():
        url = f"https://ambientcg.com/get?file={set_id}_1K-JPG.zip"
        print(f"fetching {url}")
        req = urllib.request.Request(url, headers={"User-Agent": "HypeRaiders-asset-fetch"})
        with urllib.request.urlopen(req) as resp:  # noqa: S310 - fixed https host
            data = resp.read()
        if len(data) < 100_000:
            raise RuntimeError(f"suspiciously small download: {set_id}")
        zip_path.write_bytes(data)
    if not out_dir.exists():
        with zipfile.ZipFile(io.BytesIO(zip_path.read_bytes())) as zf:
            zf.extractall(out_dir)
    return out_dir


def bake_albedo(src: Path, dst: Path, contrast: float, chroma: float) -> float:
    """Write the mean-1.0 bounded modulation map. Returns the source's linear mean."""
    rgb = np.asarray(Image.open(src).convert("RGB"), dtype=np.float32) / 255.0
    lin = np.power(rgb, 2.2)
    luma = lin @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    mean = float(luma.mean())
    rel = (luma / max(mean, 1e-5))[..., None]
    # Per-channel deviation from grey: 1.0 everywhere on a neutral texture.
    tilt = lin / np.maximum(luma, 1e-5)[..., None]
    mod = rel * (1.0 + chroma * (tilt - 1.0))
    mod = np.clip(1.0 + contrast * (mod - 1.0), MOD_LO, MOD_HI)
    enc = np.power(mod / ALBEDO_SCALE, 1.0 / 2.2)
    Image.fromarray((np.clip(enc, 0.0, 1.0) * 255.0).astype(np.uint8)).save(
        dst, quality=JPEG_Q, subsampling=0
    )
    return mean


def main() -> None:
    SCRATCH.mkdir(parents=True, exist_ok=True)
    DST.mkdir(parents=True, exist_ok=True)
    for family, (set_id, contrast, chroma) in FAMILIES.items():
        src_dir = download(set_id)
        color = src_dir / f"{set_id}_1K-JPG_Color.jpg"
        if not color.exists():
            raise RuntimeError(f"missing colour map: {color}")
        mean = bake_albedo(color, DST / f"{family}_albedo.jpg", contrast, chroma)
        src = src_dir / f"{set_id}_1K-JPG_NormalGL.jpg"
        if not src.exists():
            raise RuntimeError(f"missing map: {src}")
        Image.open(src).save(DST / f"{family}_normal.jpg", quality=JPEG_Q, subsampling=0)
        print(f"  {family:9s} <- {set_id:16s} (source linear mean {mean:.3f})")
    print(f"DONE ({len(FAMILIES)} families) -> {DST}")


if __name__ == "__main__":
    main()
