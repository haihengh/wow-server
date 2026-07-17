# wow-server — Distributed WoW Private Server Architecture

An exploration into hosting World of Warcraft private servers with a distributed,
blockchain-like architecture — enabling multiple independent hosts to run server
nodes, verify each other's game simulation, and earn rewards for contributing
compute and hosting capacity.

## Repositories Under Study

| Repository | Game Version | Status |
|---|---|---|
| [AzerothCore](azerothcore-wotlk/) | WotLK 3.3.5a | Primary — recommended foundation |
| [CMaNGOS](mangos-classic/) | Classic 1.12 | Secondary — simpler, but older patterns |

## High-Level Architecture (Current State)

Both servers share the same ancestral architecture (MaNGOS → TrinityCore → AzerothCore):

```
                    ┌──────────────┐
    Client ──TCP──► │  authserver  │  (port 3724, SRP6 login)
                    └──────┬───────┘
                           │ reads/writes
                    ┌──────▼───────┐
                    │   MySQL DB   │  ← shared state bus, NOT direct IPC
                    └──────┬───────┘
                           │ reads
                    ┌──────▼───────┐
    Client ──TCP──► │ worldserver  │  (port 8085, all game logic)
                    └──────────────┘
```

Key insight: **authserver and worldserver never communicate directly** — MySQL is
their only coupling. The worldserver is a monolithic process running a ~20 FPS tick
loop that updates everything (maps, AI, combat, spells, chat, weather, etc.).

## Server Processes

### authserver (Login)
- Port 3724 — handles SRP6 authentication
- Serves realm list to clients
- Manages account bans, session keys
- Connects only to `acore_auth` / `classicrealmd` database
- Single network thread

### worldserver (Game)
- Port 8085 — all game simulation
- Single-threaded main tick loop at ~20 FPS (50ms target)
- Connects to all three databases
- Subsystems updated each tick: sessions, maps/grids, battlegrounds, outdoor PvP,
  auction house, mail, quests, weather, game events, chat channels

## Data Stores

| Database | Contents |
|---|---|
| **Auth/Login** | Accounts, realm list, bans, session keys |
| **Characters** | Player data, inventory, quests, guilds, mail |
| **World** | Static templates (creatures, items, quests), spawns, AI scripts, game events |

## Natural Sharding Boundaries

The existing map/grid system provides the seams for distribution:

| Boundary | Description | Distribution Fit |
|---|---|---|
| **Maps** | Continents, dungeons, instances | One map = one hosting node |
| **Grids** | 16×16 cell chunks within a map | Already activate/deactivate by player proximity |
| **Instances** | Private dungeon/raid copies | Perfectly isolated — natural shard |
| **Battlegrounds** | PvP match instances | Already isolated — per-match hosting |

## Distributed Architecture Vision

See [docs/distributed-architecture.md](docs/distributed-architecture.md) for the
full design document covering:

1. **Service decomposition** — splitting the worldserver monolith
2. **Consensus model** — how nodes agree on game state
3. **Deterministic simulation** — requirements for verifiable replay
4. **Token economics** — reward mechanism for hosting nodes
5. **Phased implementation roadmap** — incremental path from monolith to mesh

## Quick Start (Local Exploration)

```bash
# AzerothCore (WotLK 3.3.5a) — recommended
cd azerothcore-wotlk
# See docker-compose.yml for full stack (authserver + worldserver + MySQL)
docker compose up -d

# CMaNGOS (Classic 1.12) — simpler, for comparison
cd mangos-classic
# Build from source with CMake
```

## License

The analysis and design documents in this repository are for research purposes.
AzerothCore is GPLv2. CMaNGOS is GPLv2.
