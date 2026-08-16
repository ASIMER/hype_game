# Asset Catalog & Credits — Hype Raiders

Persistent record of the asset research sweep + what's integrated. Return here to re-find sources, check licenses, or pick up deferred items. Raw download samples live in the gitignored `asset-research/` (547 MB scratch); only the chosen files are committed into `assets/` / `addons/`.

**Status legend:** ✅ INTEGRATED · ⏳ DEFERRED (planned later) · ❌ REJECTED · 🔎 ALTERNATE (vetted backup).

## License posture
All SHIPPED assets are **CC0** (public domain, no attribution required), **MIT**, or **CC BY 3.0** (the Power-buff + skill-hotbar UI icons from game-icons.net) — attribution for the latter two is kept in this file (+ the addon's own LICENSE). **No proprietary-EULA audio (Ovani/Sonniss) is committed** — their licenses forbid exposing raw files in a public repo. Synty is paid (not used).

---

## Integrated this batch (`feat/asset-integration`)

| Asset | Category | Source | License | Status | Where used |
|---|---|---|---|---|---|
| **GodotGrass** (2Retr0 / Ethan Truong) | Grass shader | https://github.com/2Retr0/GodotGrass | MIT | ✅ | `shaders/grass.gdshader` — SSS + root→tip gradient + Perlin wind + AO + view-space widening, ported onto our tiled MultiMesh grass |
| **Sky3D** (TokisanGames) | Sky plugin | https://store.godotengine.org/asset/tokisangames/sky3d/ · https://github.com/TokisanGames/Sky3D | MIT | ✅ | `addons/sky_3d/` — replaces `sky_storm.gdshader`; day→storm tween retargeted in `world_atmosphere.gd` |
| **Stylized Nature MegaKit** (Quaternius) | Trees/rocks/bushes/clutter | https://quaternius.com/packs/stylizednaturemegakit.html · https://quaternius.itch.io/stylized-nature-megakit | CC0 | ✅ | `assets/models/flora/` — 15 tree variants (Common/Pine/Dead/Twisted ×biome mixes), bushes, rocks + the vegetation-overhaul CLUTTER set (Fern_1, Clover_1/2, Flower_3/4_Group, Mushroom_Common/Laetiporus, Plant_1/7, Pebble_Round/Square ×5, RockPath_*_Wide) used by `procedural_flora.gd` + `flora_clutter.gd` |
| **ambientCG Ground003** (grass-dirt) | PBR ground tex | https://ambientcg.com/view?id=Ground003 | CC0 | ✅ | `assets/textures/ground/` — terrain low/flat blend (**2K** since the graphics overhaul; fetch via `tools/art/fetch_ground_textures.ps1`) |
| **ambientCG Ground054** (dirt) | PBR ground tex | https://ambientcg.com/view?id=Ground054 | CC0 | ✅ | terrain mid-elevation blend (**2K**) |
| **ambientCG Rock029** (warm rock) | PBR ground tex | https://ambientcg.com/view?id=Rock029 | CC0 | ✅ | terrain steep-slope/cliff blend (**2K**) |
| **ambientCG Gravel022** (crushed stone) | PBR ground tex | https://ambientcg.com/view?id=Gravel022 | CC0 | ✅ | terrain 4th layer — ragged gravel APRONS around POI/zone pads (baked pad mask, `procedural_terrain.gd`) |
| **ambientCG Rock035** (dark cliff) | PBR ground tex | https://ambientcg.com/view?id=Rock035 | CC0 | 🔎 | alt cliff (storm/shadowed) |
| **ambientCG Concrete016 / MetalPlates013 / Rust004 / Plaster001 / Planks011 / Rock022 / Bricks023** | PBR facade tex | https://ambientcg.com/view?id=Concrete016 (etc.) | CC0 | ✅ | `assets/textures/facade/` — the 7 building-surface families (D3.1), fetched + baked by `tools/art/fetch_facade_textures.py`, consumed via `ProcMaterials.apply_pbr`. **The shipped `*_albedo.jpg` is NOT the source colour map**: it is a mean-1.0 bounded modulation bake (half-scale encoded) so the authored `mat_*` palette survives untouched — see the tool's docstring. Normals ship as-is; roughness maps are deliberately not shipped (a texture multiply into a matte scalar clamps at 1.0 and cannot be compensated back). |
| **Sci-Fi Modular Gun Pack** (Quaternius) | Weapons | https://quaternius.com/packs/scifimodularguns.html | CC0 | ✅ | `assets/models/weapons/` → `AssetRegistry` rifle/pistol/smg/shotgun/dmr |
| **Blaster Kit** (Kenney) | Weapons (fallback) | https://kenney.nl/assets/blaster-kit | CC0 | ✅/🔎 | reliable CC0 GLB fallback for gun ids + projectiles/crates |
| **Gunshot Sounds** (recorded firearms) | Audio | https://opengameart.org/content/gunshot-sounds | CC0 | ✅ | `assets/audio/shot_{pistol,rifle,smg,shotgun,dmr}.wav` — real CZ-52 pistol / SKS rifle / Mosin (DMR) / shotgun, per-weapon-class gunfire (SMG reuses the pistol crack, pitched up). Replaces the old synthetic "laser" shot. |
| **Loopable Dungeon Ambience** (qubodup) | Audio | https://opengameart.org/content/loopable-dungeon-ambience | CC0 | ✅ | `assets/audio/ambient.ogg` — low wind ambience bed (looped in-raid). |
| **Dark Shrine Loop** (qubodup) | Audio | https://opengameart.org/content/dark-shrine-loop | CC0 | ✅ | `assets/audio/music.ogg` — quiet tense dark-ambient music bed (looped, raised slightly during waves). |
| **Procedural SFX** (self-generated) | Audio | `tools/audio/gen_audio.py` (procedural) | CC0 (own work) | ✅ | The remaining minor SFX: `hit`/`explosion`/`reload`/`ui_click`/`extract_*`/`wave_alert`/`win`/`lose`/`footstep*`/`weapon_switch`/`heartbeat`/`water_splash`/`underwater`/`glass_break`/`chunk_{concrete,metal,stone}` (material-typed collapse). Gunshots + ambient + music beds are the CC0 recordings above. Refetch the recordings with `tools/audio/fetch_real_audio.ps1`. |
| **Power-buff icons** (game-icons.net) | UI icons | https://game-icons.net (raw: github.com/game-icons/icons) | **CC BY 3.0** (attribution below) | ✅ | `assets/ui/icons/powers/*.svg` — the 9 Power Cache buff icons (white-on-transparent, tinted per power). Refetch with `tools/art/fetch_power_icons.ps1`. By **Lorc, Sbed** (game-icons.net): berserk=`lorc/battle-axe`, rapidfire=`lorc/minigun`, swift=`lorc/wingfoot`, overshield=`lorc/checked-shield`, regen=`sbed/health-increase`, lifesteal=`lorc/bleeding-heart`, juggernaut=`lorc/breastplate`, adrenaline=`lorc/energise`, frenzy=`lorc/star-swirl`. |
| **Upgrade icons** (game-icons.net) | UI icons | https://game-icons.net (raw: github.com/game-icons/icons) | **CC BY 3.0** (attribution below) | ✅ | `assets/ui/icons/upgrades/*.svg` — the 5 Hub credit-upgrade icons (white-on-transparent, tinted per upgrade). Refetch with `tools/art/fetch_upgrade_icons.ps1`. By **Lorc, Delapouite** (game-icons.net): player_health=`lorc/glass-heart`, reload_speed=`delapouite/machine-gun-magazine`, stamina=`lorc/run`, weapon_damage=`lorc/bullets`, stash_capacity=`delapouite/backpack`. |
| **Skill icons** (game-icons.net) | UI icons | https://game-icons.net (raw: github.com/game-icons/icons) | **CC BY 3.0** (attribution below) | ✅ | `assets/ui/icons/skills/*.svg` — the 10 Mutant-Harvest skill-hotbar icons (white-on-transparent, tinted per skill colour). Refetch with `tools/art/fetch_skill_icons.ps1`. By **Lorc, Delapouite** (game-icons.net): leap=`delapouite/leapfrog`, slam=`lorc/stomp`, blink=`lorc/teleport`, mortar=`delapouite/mortar`, shield=`lorc/checked-shield`, ram=`lorc/horned-helm`, chainshock=`lorc/lightning-arc`, bite=`lorc/sharp-smile`, whirlwind=`lorc/tornado`, recon=`lorc/eyeball`. |
| **Procedural player** (own work) | Player character | `scripts/visual/procedural_player.gd` | CC0 (own work) | ✅ | The player is now a PROCEDURAL modular robot (head/torso/arms/legs/paint, ≥10 variants each) for the customization constructor — like the enemies. `assets/models/characters/raider.glb` (Kenney) is **no longer used** (`AssetRegistry.get_model("player")` builds procedurally). |
| **Russo One** (Google Fonts) | UI font (headings) | https://fonts.google.com/specimen/Russo+One · https://github.com/google/fonts/tree/main/ofl/russoone | SIL OFL 1.1 (`assets/fonts/OFL-RussoOne.txt`) | ✅ | `assets/fonts/RussoOne-Regular.ttf` → theme `HeaderLarge`/`HeaderSmall` variations (condensed military caps; Latin + **Cyrillic** for the RU locale) |
| **Oswald** (Google Fonts) | UI font (legacy body) | https://fonts.google.com/specimen/Oswald · https://github.com/google/fonts/tree/main/ofl/oswald | SIL OFL 1.1 (`assets/fonts/OFL-Oswald.txt`) | ✅ | `assets/fonts/Oswald-Regular.ttf` — **replaced as the theme body font by Inter** (UI-redesign Phase 5: the 4-critic panel unanimously flagged condensed Oswald as illegible below ~16px). Kept on disk/licensed; no theme reference. Static instance (weight 400) via `fontTools.varLib.instancer` — the variable TTF caused per-glyph baseline jitter in Godot's dynamic rasterizer. |
| **Inter** (Google Fonts) | UI font (body) | https://fonts.google.com/specimen/Inter · https://github.com/google/fonts/tree/main/ofl/inter | SIL OFL 1.1 (`assets/fonts/OFL-Inter.txt`) | ✅ | `assets/fonts/Inter-Regular.ttf` → theme `default_font` (15px; Label/Button/LineEdit; Latin + **Cyrillic**). A true UI sans — replaced condensed Oswald for small-size legibility. **Static instance** (`opsz=14 wght=400` via `fontTools.varLib.instancer`) — same variable-TTF baseline-jitter trap as Oswald. |

---

## Deferred (planned, not this batch)

| Asset | Category | Source | License | Why deferred |
|---|---|---|---|---|
| **Sci-Fi Essentials Kit** + robot GLBs (Quaternius) | Enemy robots | https://quaternius.itch.io/sci-fi-essentials-kit · poly.pizza CC0 robots | CC0 | Current procedural robots are animated (rotor spin/core pulse); add Quaternius bots as NEW enemy types in a future "new enemies" batch. 3 robot GLBs already in `asset-research/characters-weapons/sample/quaternius_robots/` |
| **Ultimate Stylized Nature Pack** (Quaternius) | Detailed rocks/ruins | https://quaternius.com/packs/ultimatestylizednature.html | CC0 | itch-gated; optional detailed-rock companion to the MegaKit |
| **Voxel Destruction** (Terabase) | Destructible cover | https://godotengine.org/asset-library/asset/3743 · https://github.com/Terabase-Studios/Godot-Voxel-Destruction | MIT | Needs a voxel `.vox` art pipeline (our buildings are procedural mesh); own feature batch |
| **Ultimate Modular Men** (Quaternius) | Player character | https://quaternius.com/packs/ultimatemodularcharacters.html | CC0 | sci-fi soldier for the player model, later |

---

## Rejected

| Asset | Category | Source | License | Why |
|---|---|---|---|---|
| **Terrain3D** (TokisanGames) | Terrain system | https://github.com/TokisanGames/Terrain3D | MIT | Photoreal (clashes with stylized); **breaks our runtime `NavigationRegion3D.bake_navigation_mesh()`** (needs its own baker + painted navigable areas + Full collision off camera-relative default); adds a **C++ GDExtension binary** to our binary-free headless/`--server`/portable-export/co-op pipeline — for a small gain on a 160×160 mostly-flattened arena |
| **TerraBrush** (spimort) | Terrain tool | https://store.godotengine.org/asset/spimort/terrabrush/ | MIT | Alpha-stage, weaker than Terrain3D; same GDExtension concern |
| **Ovani Sound FX Starter** | Audio | https://store.godotengine.org/asset/ovani-sound/sound-fx-starter-pack-vol/ | Proprietary royalty-free EULA | EULA forbids distributing raw files standalone / in a public repo. Usable only embedded-in-build, out of the source tree — not worth the friction vs Kenney CC0 |
| **Multimesh Grass** (asset 743) | Grass demo | https://godotengine.org/asset-library/asset/743 | MIT | Godot 3.x (`VisualServer` API), obsolete |
| **HDRI skies** (Poly Haven) | Sky | https://polyhaven.com/hdris | CC0 | Static panorama can't do our day→storm transition; Sky3D wins here |

---

## Other vetted sources (for future searches)

| Source | URL | License | Best for |
|---|---|---|---|
| Quaternius | https://quaternius.com | CC0 | **Best style-fit** stylized-detailed models (nature, sci-fi, characters, weapons) |
| ambientCG | https://ambientcg.com | CC0 | PBR ground/rock/material textures (albedo+normal+roughness) |
| Poly Haven | https://polyhaven.com | CC0 | PBR textures, HDRIs, photoscan models (often too heavy/realistic for us) |
| Kenney | https://kenney.nl | CC0 | Audio, props, UI, low-poly kits |
| OpenGameArt | https://opengameart.org | mixed (filter CC0) | grass alpha cards (`vegetation_grass_card_03.png` CC0), ambient music |
| Godot Asset Store / GitHub | https://store.godotengine.org | mostly MIT | plugins/systems (Sky3D, GodotGrass, ProtonScatter) |
| Freesound | https://freesound.org | mixed (filter CC0) | specific gun/robot/ambient one-shots |

**Alternate grass leads (backup):** Simple Grass Textured (IcterusGames, MIT, `addons/`, in-editor paint + player-bend — https://github.com/IcterusGames/SimpleGrassTextured); ProtonScatter (HungryProton, MIT, scatter tool — https://github.com/HungryProton/scatter); OpenGameArt CC0 grass card (https://opengameart.org/content/grass-blades-alpha-card-texture-side-view).

---

## Credits
- **GodotGrass** grass shader technique — © 2024 Ethan Truong (2Retr0), MIT.
- **Sky3D** — © 2023-2025 Cory Petkovsek & contributors / © 2021 J. Cuéllar, MIT (see `addons/sky_3d/LICENSE.txt`).
- **Quaternius** (Tomás Laulhé) nature/sci-fi/weapon models — CC0.
- **ambientCG** (Lennart Demes) PBR textures — CC0.
- **Kenney** (Kenney Vleugels) audio + blaster kit — CC0.
