# Hype Raiders

An **Arc Raiders-style co-op third-person extraction shooter** vertical slice built in **Godot 4.6.3**. Scavenge a hostile 160×160 urban-ruins map full of AI robots, survive escalating waves (including a boss), and reach an extraction zone alive — solo or in up to **8-player** co-op. Death loses your at-risk gear; extracting keeps your haul. It runs with **zero art assets** — every model falls back to a procedurally-built or tinted primitive via `AssetRegistry`, so the game is always runnable.

## Run

```
& "C:\Users\illya\Desktop\godot\Godot_v4.6.3-stable_win64.exe" --path "C:\personal\hype game"
```

From the menu: **Single Player**, **Host Co-op**, **Join Co-op**, or the **Servers** browser (direct-connect by IP, favorites, recents, LAN scan). Co-op is over UDP 24565.

## Build a portable Windows .exe

```
pwsh tools/build/export_windows.ps1
```

Exports a single self-contained `export/HypeRaiders.exe` (game data embedded) and zips it with a friend-facing README — hand the zip to friends, they unzip and run.

## Docs

- **[CLAUDE.md](CLAUDE.md)** — read first: the always-loaded project index.
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — autoloads, the Events bus, Settings, physics layers, scene trees, every gameplay system.
- **[docs/TESTING.md](docs/TESTING.md)** — the self-play test harness (how to drive/screenshot the game) + QA workflow + full control/`state` reference.
- **[docs/AGENT_TEAMS.md](docs/AGENT_TEAMS.md)** — the agent-team structure & file-ownership model for parallel work.
