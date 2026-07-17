# Distributed WoW Server Architecture — Design Document

## 0. Legal Position & Threat Model (read first)

### 0.1 Legal position

This project is research/design-only. Before any public deployment is
considered, resolve the following — they change the design, not just the
disclaimer text:

- **Copyright/EULA exposure**: WoW private servers already sit in a legally
  gray/unauthorized zone under Blizzard's EULA and prior enforcement history.
  Adding financial incentives (a token with real or exchange value) turns a
  hobby-project risk into a commercial-infringement + possible
  money-transmission/securities-law question. Treat this as a blocking
  decision, not a footnote.
- **Token design decision (must be made before §5 is finalized)**: choose one
  of:
  1. **Non-transferable contribution credit** (internal point system, no
     external exchange value) — materially lower legal exposure, but weaker
     incentive design.
  2. **Tradeable token** — stronger incentive design, but requires legal
     counsel review (securities law, money transmission) before any code
     that mints/transfers value is written.
  The rest of this document assumes decision 1 unless/until counsel says
  otherwise. Any tokenomics work in §5 is illustrative, not a commitment.
- This repo will not operate a public/shared realm. All exploration is local
  or private-network only until the above is resolved.

### 0.2 Threat model

Two distinct classes of "attacker" apply here, with different mitigations:

| Actor | Goal | Mitigation |
|---|---|---|
| **Malicious/Byzantine node** | Forge state, double-spend rewards, censor players | Consensus + slashing (§3) |
| **Colluding validator cartel** | Approve invalid epochs as a group to split rewards | Requires randomized/rotating validator selection + minimum honest-majority assumption; not yet designed — open question |
| **Sybil host** | Register many low-cost identities to dominate proposer selection | Staking cost per identity (§5.2) |
| **Legal/takedown actor** (e.g., rights holder, regulator) | Shut down the network, seize infrastructure | Out of scope for technical mitigation; addressed only by §0.1 legal decisions, not architecture |

The rest of this document addresses the first two rows in detail. The last
row is a reminder that no amount of P2P/consensus design solves the legal
problem — don't over-invest in decentralization as a legal shield without
counsel confirming it helps.

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

**Decision: option 3 (zone-based sharding) is the recommended default.**
Options 1 and 2 solve real-time grid-boundary sync but add substantial
complexity (see Phase 4 status note below) for a problem zone-based sharding
avoids by construction. Grid-level sharding (options 1/2) remains a
documented fallback only if zone-based load balancing proves insufficient —
see the Phase 4 entry in §6 for the exact trigger condition.

### 2.4 Worked Example: Player Kills a Creature

To make the architecture concrete, here's how a single player action flows
through the distributed system:

```
Player casts Fireball at a wolf in Elwynn Forest.
Elwynn Forest is hosted on Map Node A.

Step  Client              World Router        Map Node A          Consensus

1.    Send CMSG_CAST_     ──forward──►        Receive spell
      SPELL (wolf GUID)                       cast request

2.                                            Validate: player
                                              has mana? spell
                                              off cooldown? in
                                              range? LOS clear?

3.                                            Execute tick:
                                              - Deduct mana
                                              - Compute damage
                                              - Apply to wolf
                                              - Remove wolf if
                                                health ≤ 0
                                              - Generate loot
                                              - Award XP

4.                                            At epoch end,
                                              produce State Diff:
                                              {player.mana -= X,
                                               wolf: DELETED,
                                               corpse: CREATED,
                                               loot: CREATED,
                                               player.xp += Y}
                                              + Input Log entry
                                              ──submit──►

5.                                                         Verifier
                                                            replays inputs,
                                                            computes same
                                                            State Root,
                                                            votes accept
```

**Things to notice:**

- Steps 1-3 happen **immediately** (optimistic execution). The player sees
  the fireball hit, the wolf die, and the loot sparkle all within a single
  tick — no consensus delay.
- Consensus (steps 4-5) happens **asynchronously** at epoch boundaries. The
  player doesn't wait for it. If the epoch is later rejected, a rollback
  occurs (see §2.5).
- Cross-service interactions (chat message about the kill, guild achievement
  progress, auction house if the loot gets listed) are separate async events
  fanned out from Map Node A to the relevant services — not part of the
  combat hot path.
- The **World Router** is a thin proxy here: it routes the client's TCP
  stream to whichever Map Node owns the player's current zone. It doesn't
  inspect or validate game packets.

### 2.5 Failure Modes & Recovery

#### 2.5.1 Map Node Crash (Mid-Epoch)

If a Map Node crashes before submitting its epoch:

- **Detection**: World Router's heartbeat to the node times out (suggested:
  3× tick interval = 150ms).
- **Player impact**: All players on that node's maps get a loading screen
  (the existing WoW client behavior for a server disconnect).
- **Recovery**:
  1. World Router marks the node's current epoch as abandoned.
  2. Router reassigns the node's maps to other Map Nodes (or spawns a
     replacement).
  3. Replacement node loads the **last committed epoch's state** for those
     maps from the consensus log (static data from the World DB, entity
     state from the state trie).
  4. Players reconnect transparently — their character state rolls back to
     the last committed epoch (at most ~10 seconds of progress lost).
  5. If the crashed node had submitted a partial epoch that verifiers had
     started replaying, verifiers discard it when the epoch's proposer slot
     is declared vacant.

**Design decision: players lose at most one epoch of progress on crash.**
This is the optimistic-execution tradeoff — fast responses in exchange for
occasional small rollbacks. For a research/private-server context, this is
acceptable. For a production-hardened system, this would need refinement.

#### 2.5.2 World Router Crash

- **Detection**: Client TCP disconnect + authserver heartbeat timeout.
- **Recovery**: The Router is stateless (session → Map Node mapping is
  derivable from the consensus log). A replacement Router reconnects
  clients to their last known Map Node.
- **Mitigation**: Run multiple Router instances behind a TCP load balancer
  or use DNS failover. Since the Router only proxies and doesn't hold game
  state, hot standby is straightforward.

#### 2.5.3 Consensus Stall (No Epoch Finalized)

If verifiers cannot reach consensus on an epoch:

- **Cause**: Non-deterministic simulation bug, malicious proposer, or
  network partition among verifiers.
- **Detection**: Epoch remains un-finalized beyond a timeout (suggested:
  5× epoch duration).
- **Recovery**:
  1. The proposer's stake is frozen pending investigation.
  2. Verifiers fall back to a **replay-from-last-known-good** checkpoint:
     discard the disputed epoch, re-simulate from the last committed state
     with the same Input Log, but on a single canonical verifier node to
     produce a reference result.
  3. If the reference result matches the proposer: consensus resumes
     (verifier bug). If it differs: proposer slashed, epoch discarded,
     next proposer in rotation picks up.

#### 2.5.4 Client Protocol Constraints

The WoW client is a **closed binary that speaks a fixed protocol**. This
imposes hard constraints on the distributed design:

| Constraint | Impact |
|---|---|
| **Single TCP connection** — the client connects to one server IP:port and expects to stay connected | The World Router must proxy the same TCP stream for the entire session; the client cannot be told "reconnect to this other Map Node now" without a loading screen |
| **Loading screens are the only redirect points** — the client already accepts a new server address at zone transitions and instance portals | Zone-based sharding (§2.3 option 3) is the only approach that works **without client modifications** |
| **Opcodes are fixed** — we can't add new packet types for cross-node sync | All distributed-system protocol is server-side only; the client sees the same opcode stream it always has |
| **No client-side consensus awareness** — the client can't participate in verification or hold tokens | The token and consensus layer is entirely invisible to the game client |

**Implication**: The World Router can't just hand the client a new TCP
endpoint mid-session. It must either (a) proxy the byte stream
transparently to the correct Map Node, or (b) use the existing loading-screen
mechanism to redirect. Approach (a) adds latency (an extra hop through the
Router). Approach (b) is free but limited to zone boundaries. The Phase 2-3
plan uses (b) for zone transitions and (a) as a fallback for intra-zone
operations like chat and mail.

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
**TBD**: this value is illustrative, not derived from data. It should be set
after Phase 0 profiling shows how much state-diff/Input-Log volume a real
raid-sized epoch produces, and after §3.3.1's verification-cost analysis
sets an upper bound on safe epoch size.

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

### 3.3.1 Verification Cost Asymmetry (open risk)

Naive replay-verification has a structural weakness: verifying an epoch
costs roughly the same CPU as producing it (unless the verifier has spare
capacity). This creates two exploitable gaps:

- **Asymmetric DoS**: a proposer can pack an epoch with worst-case-expensive
  content (e.g., a full 40-player raid with heavy AoE/threat-table churn, or
  many simultaneous pathfinding requests) that costs the proposer normal
  compute but pushes verifiers toward their capacity limit — especially
  problematic if verifier count is small relative to proposer throughput.
- **Under-verification incentive**: if verification isn't profitable relative
  to its cost, rational verifiers skip it, weakening the security model.

Mitigations to design before implementing consensus (not yet resolved):
- **Bounded epochs**: cap entities/ticks/actions per epoch so worst-case
  verification cost has a known ceiling (trades off epoch throughput).
  Compute-proportional staking: `required_stake ∝ declared entity/tick count`, so
  proposers can't cheaply claim to have done more work than a lightweight,
  low-stake identity can be trusted for.
- **Verification reward must exceed replay cost** in the reward split (§5.3)
  — the 30% verifier pool figure there is a placeholder, not a value derived
  from actual replay-cost measurements.

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

**TBD**: this table and recommendation are candidate options, not a
protocol selection — no prototyping or benchmarking has been done yet. Pin
down actual numbers (real HotStuff/Tendermint latency under realistic
validator counts) before committing engineering effort to either.

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
| Recast/Detour navmesh pathfinding | Not guaranteed bit-identical across compilers/architectures even with strict floating-point mode; runs every tick for every moving creature — larger surface area than the RNG issue above | Either pin a single pathfinding build (same binary/arch for all proposer+verifier nodes, sacrificing "any hardware" goal) or replace with a deterministic fixed-point path solver; unresolved — needs its own investigation before Phase 4/5 |
| Network jitter / action ordering | Two players' near-simultaneous actions can arrive in different relative order depending on network timing, producing different (but each individually "valid") outcomes | Define a canonical ordering rule up front — e.g., order by (server-received tick, connection sequence number, player GUID) — and record the resulting order in the Input Log itself, not just raw arrival order, so replay is unambiguous |

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

**TBD**: the 50/30/15/5 split and decay curve are placeholders for
illustration only. The verifier-pool share in particular must be set high
enough to exceed replay cost (see §3.3.1) or verification participation
will collapse; don't treat these percentages as settled until that's
modeled. Also revisit §0.1's token-design decision before implementing any
of this — a non-transferable credit system may not need a "Fee Pool" or
"Treasury/DAO" concept at all.

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

### Phase 4 — Grid-Level Sharding (provisional — see §2.3 decision)

The hardest step — shard within a single map:
- Adjacent grids on different nodes
- Requires real-time boundary synchronization
- This is where the deterministic simulation engine is essential

```
Goal: A single continent split across multiple nodes at grid boundaries.
      Players can see and interact across node boundaries seamlessly.
```

**Status: not committed.** §2.3 lists zone-based sharding as an alternative
to grid-level sharding that avoids real-time cross-node combat entirely by
reusing existing loading-screen boundaries. Zone-based sharding is the
*default target* for the mesh's long-term steady state — it is simpler,
lower-risk, and may be sufficient. Grid-level sharding should only be
pursued past Phase 3 if profiling shows zone-based sharding produces
unacceptable load imbalance (e.g., one zone consistently overloaded — think
a capital city hub). Do not start Phase 4 work until that data exists.

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

## 6.5 Non-Goals (v1 scope boundary)

To keep scope from creeping ahead of what's actually been validated, the
following are explicitly **out of scope** until the stated gate is met:

- **No tradeable/exchange-value token** until §0.1's legal decision is made
  with counsel input. Default assumption for all current work: internal,
  non-transferable contribution credit only.
- **No grid-level sharding (Phase 4)** until Phase 3 (zone-based sharding)
  is running and profiling shows a specific load-imbalance problem it
  can't solve.
- **No public/shared realm deployment** — all work is local/private-network
  exploration until legal review is complete.
- **No CMaNGOS distributed implementation** — CMaNGOS stays reference-only
  (§9); all phased work targets AzerothCore.
- **No committed epoch size, reward split, or consensus protocol** — the
  numbers in §3.2, §3.4, and §5.3 are placeholders pending Phase 0
  profiling data; do not hardcode them into any prototype without first
  gathering that data.
- **No NAT traversal / P2P networking implementation** in early phases —
  Phases 1-3 assume operator-run nodes with public reachability (like
  today's private servers); permissionless home-hosting (§7 open question
  6) is deferred to Phase 5+.

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

**Scope note**: The phased roadmap (§6) and file references throughout this
document target **AzerothCore only**. CMaNGOS is retained in the repo as a
comparative reference for Phase 0 profiling (simpler codebase, useful for
validating that the architectural patterns in §1 generalize across
MaNGOS-lineage servers) but is *not* a second implementation target — doing
so would double the Phase 0-5 analysis and engineering work for uncertain
benefit. If CMaNGOS-specific distributed work becomes valuable later, treat
it as a separate follow-on effort with its own roadmap, not a parallel track
of this one.

### AzerothCore
| File | What It Does |
|---|---|
| `src/server/apps/worldserver/Main.cpp` | Entry point, startup sequence |
| `src/server/game/World/World.cpp` | `World::Update()` — the main loop |
| `src/server/game/Maps/Map.cpp` | `Map::Update()` — per-map tick |
| `src/server/game/Maps/MapUpdater.cpp` | Parallel map update scheduling |
| `src/server/game/Server/WorldSocket.cpp` | Client TCP connection handler |
| `src/server/database/DatabaseWorkerPool.h` | DB connection pooling |

### CMaNGOS (reference only — see scope note above)
| File | What It Does |
|---|---|
| `src/mangosd/Main.cpp` | Entry point |
| `src/mangosd/WorldRunnable.cpp` | Main game loop thread |
| `src/game/World/World.cpp` | `World::Update()` |
| `src/game/Maps/Map.cpp` | Per-map simulation |
| `src/game/Server/WorldSocket.cpp` | Client connection handler |
| `src/shared/Database/DatabaseMysql.cpp` | MySQL implementation |
