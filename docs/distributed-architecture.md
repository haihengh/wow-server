# Distributed WoW Server Architecture — Design Document

## 1. Current State: Monolithic worldserver

Both AzerothCore and CMaNGOS share the same fundamental architecture. The
worldserver is a single process with a single-threaded main loop:

```
while (!World::IsStopped()) {
    uint32 diff = getMSTimeDiff();
    sWorld.Update(diff);    // <-- everything happens here
    sleep(target - actual);
}
```

`World::Update(diff)` calls ~15 subsystems sequentially:

```
1. Game time update
2. Session processing (all player packets)
3. Map updates (all loaded maps → grids → creatures → objects)
4. Battleground updates
5. Outdoor PvP updates
6. World state updates
7. Auction house processing
8. Mail expiration
9. LFG updates
10. Group/guild maintenance
11. Corpse cleanup
12. Async SQL callback drain
13. Game event updates
14. DB keepalive pings
```

### What This Means for Distribution

- The worldserver already traverses all loaded maps each tick
- Each map manages its own grids, creatures, and objects
- Grids already activate/deactivate based on player proximity
- **The sharding boundary exists in the code — it's just not exposed as a network boundary**

---

## 2. Target Architecture: Distributed Service Mesh

### 2.1 Service Decomposition

```
                         ┌─────────────────┐
                         │   Auth Service   │  Login + realm list
                         └────────┬────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              │                   │                   │
     ┌────────▼────────┐ ┌───────▼───────┐ ┌────────▼────────┐
     │  World Router   │ │  Chat Service │ │  Auction Service│
     │  (connection    │ │  (channels,   │ │  (async,        │
     │   broker)       │ │   whispers)   │ │   DB-backed)    │
     └────────┬────────┘ └───────────────┘ └─────────────────┘
              │
    ┌─────────┼─────────┬──────────────┐
    │         │         │              │
┌───▼───┐ ┌──▼──┐ ┌────▼────┐ ┌──────▼──────┐
│ Map   │ │ Map │ │ Instance│ │ Battleground │
│ Node  │ │ Node│ │ Node    │ │ Node         │
│(Grids │ │     │ │(Dungeon)│ │(PvP match)   │
│ 0-127)│ │     │ │         │ │              │
└───────┘ └─────┘ └─────────┘ └──────────────┘
```

### 2.2 Node Responsibilities

| Service | Owns | Communicates With |
|---|---|---|
| **Auth Service** | Account credentials, realm list, session keys | Client, World Router, Consensus Log |
| **World Router** | Client connections, character list, realm join | Client, Auth, all Map Nodes |
| **Map Node** | One or more maps, their grids, creatures, objects | Client (via Router), neighbor Map Nodes, Consensus Log |
| **Instance Node** | One dungeon/raid instance (private copy) | Client (via Router), Consensus Log |
| **Battleground Node** | One PvP match instance | Client (via Router), Consensus Log |
| **Chat Service** | Chat channels, guild chat, whispers, party chat | Client (via Router), Consensus Log |
| **Auction Service** | Auction listings, bids, expirations | Client (via Router), Consensus Log |
| **Group/Guild Service** | Party/raid/guild membership and state | Client (via Router), Consensus Log |

### 2.3 Cross-Node Communication Patterns

**Grid boundaries** (highest bandwidth): When a player stands near a grid
boundary, two adjacent grid nodes must exchange:

- Object visibility updates (what the player sees across the line)
- Combat events (ranged attacks, AoE spells crossing grids)
- Movement transitions (player rides from grid A → grid B)

This is the hardest problem. Solutions:

1. **Owner-based authority**: grid A node has authority for objects on A's side.
   It pushes state snapshots to grid B node for visibility only.
2. **Boundary buffer zone**: overlapping authority in boundary cells; both
   nodes simulate, one is canonical.
3. **Zone-based sharding instead**: shard at zone boundaries (where loading
   screens already exist) to avoid real-time cross-node combat entirely.

---

## 3. Consensus Model: Proof-of-Simulation

### 3.1 Core Idea

Instead of Proof-of-Work (Bitcoin) — which wastes compute on arbitrary hashes —
use **Proof-of-Simulation**: nodes earn rewards by correctly simulating game
world state. The "work" is useful (running the game), and verification is
replaying the same inputs.

### 3.2 Epoch Structure

```
┌──────────────────────────────────────────────────────────┐
│                      EPOCH N                             │
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐           │
│  │ Tick 0 │ │ Tick 1 │ │ Tick 2 │ │ Tick 3 │ ... Tick K│
│  │(50ms)  │ │        │ │        │ │        │           │
│  └────────┘ └────────┘ └────────┘ └────────┘           │
│                                                          │
│  → State Root Hash (Merkle tree of all entity states)    │
│  → Input Log (all player actions, RNG seeds)             │
│  → Node Signature                                        │
└──────────────────────────────────────────────────────────┘
```

**Epoch**: A block of K game ticks (e.g., K=200 = 10 seconds of game time).

Each epoch produces:
- **State Diff**: which entities changed, and how
- **Input Log**: ordered list of player actions + RNG seeds for each tick
- **State Root**: Merkle root of all entity states at epoch end

### 3.3 Verification

Verifier nodes receive the Input Log for an epoch and **replay it
deterministically**. If their computed State Root matches the proposer's,
the epoch is valid. If not, the proposer is slashed (loses stake).

```
Proposer Node                    Verifier Nodes
─────────────                    ──────────────
Run epoch N                      Receive Input Log + State Root
  ↓                               ↓
Collect player actions           Replay simulation
  ↓                               ↓
Run simulation ticks             Compute State Root'
  ↓                               ↓
Produce State Root               Compare: Root == Root' ?
  ↓                               ↓
Submit to consensus              Vote: accept / reject
```

### 3.4 Consensus Protocol Options

| Protocol | Latency | Throughput | Use Case |
|---|---|---|---|
| **PBFT / HotStuff** | Low (~100ms) | Medium | Instance/BG nodes (few validators) |
| **Tendermint** | Medium (~1s) | Medium | Map nodes (more validators) |
| **Optimistic Rollup** | High (~7 days challenge) | High | World state (fraud proofs) |
| **Nominated Proof-of-Stake** | Configurable | High | Validator set selection |

**Recommendation**: Hybrid approach —
- **Optimistic execution** for the main game loop (nodes execute immediately,
  publish state diffs, verifiers challenge within a window)
- **BFT consensus** for critical events (boss kills, loot drops, currency
  transfers) that need immediate finality

---

## 4. Deterministic Simulation

### 4.1 The Problem

For verification-by-replay to work, simulation must be **deterministic**:
same inputs → same outputs, on any hardware, any OS, any compiler.

Current codebases are NOT deterministic:

| Source | Problem | Fix |
|---|---|---|
| RNG (`rand()`, `urand()`) | Seeded from system time | Use deterministic PRNG (ChaCha20) with per-tick seed from Input Log |
| Floating-point math | x87 vs SSE vs ARM yields different LSBs | Fixed-point math or strict IEEE-754 mode |
| `unordered_map` iteration | Hash-dependent order, varies by platform | Always use ordered containers (`map`, `std::sort`) for any iterated collection |
| Timer-based events | Wall-clock dependent | Convert all timers to tick-count-based |
| Pointer comparison | ASLR makes addresses non-deterministic | Never use pointer values in game logic; use entity GUIDs |
| Multithreading races | MapUpdater parallel updates | Single-thread or deterministic scheduler for replay |

### 4.2 Deterministic Entity State

Define the canonical state for each entity type as a flat buffer of
fixed-size fields, suitable for Merkleization:

```cpp
struct EntityState {
    uint64 guid;
    uint32 entry;        // creature/item template ID
    uint32 map_id;
    float pos_x, pos_y, pos_z, orientation;  // or fixed-point
    uint32 health;
    uint32 mana;
    uint32 flags;        // alive, in_combat, mounted, etc.
    uint32 aura_count;
    // ... all mutable state, no pointers
};
```

---

## 5. Token Economics

### 5.1 Roles and Rewards

| Role | Action | Reward |
|---|---|---|
| **Host (Proposer)** | Runs map/grid simulation for one epoch, submits state diff | Block reward + transaction fees |
| **Verifier** | Replays and validates proposed epochs | Portion of block reward |
| **Full Node** | Stores full state history, serves queries | Storage reward |
| **Relayer** | Routes client packets between nodes | Bandwidth reward |

### 5.2 Staking and Slashing

- **Hosts stake tokens** to be eligible to propose epochs
- If a Host's epoch is successfully challenged (incorrect state), their stake
  is slashed and distributed to the challenger
- **Verifiers stake tokens** to participate in verification; incorrect votes
  are slashed
- The staking mechanism makes Sybil attacks expensive

### 5.3 Reward Distribution

```
Epoch Reward = Base Reward + Fee Pool

Base Reward decays over time (similar to Bitcoin halving)
Fee Pool = sum of in-game economic activity fees (auction cuts, etc.)

Distribution (per epoch):
  ┌──────────────────┬───────────┐
  │ Proposer         │     50%   │
  │ Verifier pool    │     30%   │
  │ Storage pool     │     15%   │
  │ Treasury/DAO     │      5%   │
  └──────────────────┴───────────┘
```

### 5.4 In-Game Token Integration

The token could serve dual purpose:
- **Server-side**: staking, rewards, governance
- **In-game**: players earn tokens for achievements, use them for services
  (transmog, name changes, cross-realm transfers)

---

## 6. Phased Implementation Roadmap

### Phase 0 — Exploration & Profiling (Current)

- [x] Clone and analyze both server codebases
- [ ] Build and run AzerothCore locally
- [ ] Profile the worldserver loop — which subsystems consume the most CPU?
- [ ] Measure DB query patterns — which tables are read vs written, at what rates?
- [ ] Map out all cross-subsystem dependencies in `World::Update()`

### Phase 1 — Extract Auction Service

The Auction House is the easiest subsystem to extract:
- Already async in both codebases (timer-driven, DB-backed)
- No real-time requirements
- Clean API boundary (list, bid, buyout, cancel)

```
Goal: Run Auction House as a separate process communicating via gRPC
      or a message queue — proving the service decomposition pattern.
```

### Phase 2 — Instance/Battleground Sharding

Instances and battlegrounds are naturally isolated:
- Players enter through a loading screen (portal/queue)
- No cross-instance interaction
- Independent map lifecycle

```
Goal: A worldserver that spawns instances on separate processes/nodes.
      Players connect to the router, which proxies them to the right
      instance node based on which dungeon/BG they're in.
```

### Phase 3 — Map Sharding

Shard the open world at zone boundaries:
- Elwynn Forest on Node A, Westfall on Node B
- Zone transitions happen at loading screens (natural seam)
- Cross-zone chat, mail, and auction still work via shared services

```
Goal: Multiple worldserver nodes, each owning a subset of continent maps.
      World Router handles zone transitions by redirecting the client.
```

### Phase 4 — Grid-Level Sharding

The hardest step — shard within a single map:
- Adjacent grids on different nodes
- Requires real-time boundary synchronization
- This is where the deterministic simulation engine is essential

```
Goal: A single continent split across multiple nodes at grid boundaries.
      Players can see and interact across node boundaries seamlessly.
```

### Phase 5 — Consensus & Token Layer

- Replace direct DB writes with a consensus log
- Implement proposer/verifier node roles
- Deploy staking contract and reward distribution
- Allow permissionless node joining

```
Goal: A fully decentralized WoW server mesh where anyone can host nodes,
      verify simulation, and earn tokens.
```

---

## 7. Open Questions

1. **Latency budget**: WoW's combat feels responsive at <100ms latency.
   Can consensus finality fit within a 50ms tick? If not, which events need
   immediate finality vs optimistic execution?

2. **Global state**: Some systems (chat, guild, auction) are inherently global.
   Do they need consensus, or can they use CRDT-based eventually-consistent
   models?

3. **Client modifications**: Will the WoW client need modifications for
   dynamic server redirection? Or can this be handled at the network layer?

4. **Copyright**: Blizzard owns WoW's assets and protocol. A distributed
   server may face different legal considerations than a private single-host
   server. This is a research project — consult legal counsel before
   operating anything public.

5. **Economic sustainability**: What in-game activities generate enough
   economic value to sustain a token economy? Or is the token purely a
   hosting incentive?

6. **NAT traversal**: Home-hosted nodes behind NAT need hole-punching or
   relay infrastructure. WebRTC? libp2p? Custom relay network?

---

## 8. Technology Candidates

| Layer | Options |
|---|---|
| **P2P Networking** | libp2p, QUIC, WebRTC, custom UDP |
| **Consensus** | Tendermint Core, HotStuff, custom PBFT |
| **Smart Contracts** | CosmWasm, EVM-compatible sidechain, custom VM |
| **State Merkleization** | Merkle-Patricia trie, Sparse Merkle tree |
| **RPC Framework** | gRPC, Cap'n Proto, custom binary protocol |
| **Message Queue** | NATS, Redis Streams, direct TCP |
| **Deterministic VM** | WASM (sandboxed simulation), custom bytecode |
| **Storage** | RocksDB, LMDB, or retain MySQL for static data |

---

## 9. Key Files to Study

### AzerothCore
| File | What It Does |
|---|---|
| `src/server/apps/worldserver/Main.cpp` | Entry point, startup sequence |
| `src/server/game/World/World.cpp` | `World::Update()` — the main loop |
| `src/server/game/Maps/Map.cpp` | `Map::Update()` — per-map tick |
| `src/server/game/Maps/MapUpdater.cpp` | Parallel map update scheduling |
| `src/server/game/Server/WorldSocket.cpp` | Client TCP connection handler |
| `src/server/database/DatabaseWorkerPool.h` | DB connection pooling |

### CMaNGOS
| File | What It Does |
|---|---|
| `src/mangosd/Main.cpp` | Entry point |
| `src/mangosd/WorldRunnable.cpp` | Main game loop thread |
| `src/game/World/World.cpp` | `World::Update()` |
| `src/game/Maps/Map.cpp` | Per-map simulation |
| `src/game/Server/WorldSocket.cpp` | Client connection handler |
| `src/shared/Database/DatabaseMysql.cpp` | MySQL implementation |
