# WoW Server — Containerized Deployment Architecture

> **Status:** Draft — for review and discussion
> **Date:** 2026-07-30

## Overview

This document outlines the architecture for running the CMaNGOS Classic 1.12 WoW server in Docker containers, with MySQL data on a host RAM disk for performance, and a GUI management application. The design supports single-machine Docker Compose today and multi-machine Kubernetes in the future.

---

## tmpfs vs Host RAM Disk

**Docker tmpfs never syncs to physical disk.** It's a pure RAM-backed filesystem — container stop, host reboot, or Docker restart = all data lost. For a database, this means one crash destroys everything unless you have continuous replication or frequent dumps running separately.

The host RAM disk approach (ImDisk + VHD) is the right choice for MySQL:

| Concern | Docker tmpfs | Host RAM Disk + VHD |
|---------|-------------|---------------------|
| Filesystem | tmpfs (limited FS semantics) | NTFS via VHD (full API) |
| InnoDB compatibility | May have issues with sparse files, async I/O | Works exactly like a real disk |
| Container restart | Data lost | Data preserved (RAM disk still mounted) |
| Sync to persistent storage | Must run mysqldump or external replication | robocopy from VHD to SSD on a schedule |
| Shutdown safety | Data gone unless manually exported | Pause before dismount, final robocopy |
| Performance | Native RAM speed | Near-native (VHD thin layer over RAM) |

**Decision:** Host ImDisk + VHD, bind-mounted into Docker MySQL container.

---

## Full Architecture

### Component Model — Separate Docker Images

```
┌──────────┐   ┌──────────┐   ┌──────────┐
│  MySQL   │   │  realmd  │   │ mangosd  │
│  8.0     │   │  auth    │   │  world   │
│ :3306    │   │ :3724    │   │ :8085    │
└────┬─────┘   └────┬─────┘   └────┬─────┘
     │              │              │
     └──────────────┼──────────────┘
                    │
           Docker network (wow-net)

     ┌──────────────┴──────────────┐
     │      Host RAM Disk (S:)     │
     │   mysql-data.vhd on R:      │
     │   robocopy ↔ SSD backup     │
     └─────────────────────────────┘
```

Each component is an independent Docker image, enabling:

- **MySQL** could move to a dedicated machine with more RAM
- **realmd** could have multiple replicas behind a load balancer
- **mangosd** instances could, in theory, split by continent/map (requires code investigation)

### Why Three Separate Images

1. **Independent scaling** — MySQL might need more resources than the game server
2. **Independent lifecycle** — update mangosd without touching MySQL or realmd
3. **Distribution** — components can run on different physical machines
4. **Fault isolation** — mangosd crash doesn't take down the database

### Connection Flow

```
WoW Client ──TCP:3724──▶ realmd ──MySQL──▶ accounts table
                              │
                        (auth OK, return realm IP)
                              │
WoW Client ──TCP:8085──▶ mangosd ◀──MySQL──▶ characters, world, etc.
```

Both realmd and mangosd connect to MySQL via the Docker network. Client connections come from outside Docker on published ports.

---

## Directory Layout

```
wow-server/
├── docker/
│   ├── docker-compose.yml              # Single-machine deployment
│   ├── docker-compose.override.yml     # Dev overrides
│   ├── mysql/
│   │   └── conf.d/
│   │       └── ramdisk.cnf             # InnoDB tuning for RAM disk
│   ├── realmd/
│   │   └── Dockerfile                  # Builds realmd image
│   └── mangosd/
│       └── Dockerfile                  # Builds mangosd image (with playerbots)
│
├── ramdisk/
│   ├── ramdisk-core.psm1               # PowerShell module: RAM disk functions
│   ├── ramdisk-ui.ps1                  # WPF GUI application
│   ├── 1-install-driver.ps1            # (existing) One-time ImDisk install
│   ├── 2-prepare-backup.ps1            # (existing) One-time MySQL data backup
│   ├── 3-start-ramdisk.ps1             # (existing) Start RAM disk + MySQL
│   ├── 4-setup-tasks.ps1               # (existing) Register scheduled tasks
│   ├── sync-to-disk.ps1                # (existing) Periodic sync job
│   └── shutdown-sync.ps1               # (existing) Shutdown cleanup
│
├── k8s/                                # Future: Kubernetes manifests
│   ├── mysql-statefulset.yaml
│   ├── realmd-deployment.yaml
│   └── mangosd-statefulset.yaml
│
├── mangos-classic/                     # (submodule)
├── classic-db/                         # (submodule)
├── mangos-install/                     # Build output → used by Dockerfiles
└── docs/
    └── architecture/
        └── containerized-deployment.md  # This document
```

---

## Phase 1: Docker Compose (Single Machine)

### docker-compose.yml (conceptual)

```yaml
version: "3.8"

services:
  mysql:
    image: mysql:8.0
    container_name: wow-mysql
    volumes:
      # RAM disk — must be mounted before docker-compose up
      - S:/:/var/lib/mysql
      # Custom InnoDB config for RAM disk performance
      - ./mysql/conf.d:/etc/mysql/conf.d
    environment:
      MYSQL_ROOT_PASSWORD: hmahxe11
    ports:
      - "3306:3306"
    networks:
      - wow-net
    restart: unless-stopped

  realmd:
    build: ./realmd
    container_name: wow-realmd
    volumes:
      - ../mangos-install/etc/realmd.conf:/etc/mangos/realmd.conf:ro
    ports:
      - "3724:3724"
    networks:
      - wow-net
    depends_on:
      mysql:
        condition: service_healthy

  mangosd:
    build: ./mangosd
    container_name: wow-mangosd
    volumes:
      - ../mangos-install/etc/mangosd.conf:/etc/mangos/mangosd.conf:ro
      - ../mangos-install/data:/var/lib/mangos/data:ro  # maps, dbc, vmaps, mmaps
    ports:
      - "8085:8085"
    networks:
      - wow-net
    depends_on:
      mysql:
        condition: service_healthy
      realmd:
        condition: service_started

networks:
  wow-net:
    driver: bridge
```

### Dockerfile — realmd (conceptual)

```dockerfile
FROM mcr.microsoft.com/windows/servercore:ltsc2025
# Or use a custom image with pre-built binaries
# Strategy: build on host, copy binaries into image

COPY ./bin/realmd.exe /app/realmd.exe
COPY ./etc/realmd.conf /etc/mangos/realmd.conf

EXPOSE 3724
CMD ["C:\\app\\realmd.exe", "-c", "C:\\etc\\mangos\\realmd.conf"]
```

> **Open Question:** Build inside Docker (multi-stage with VS Build Tools) or build on host and copy into image?
> - **Host-build + copy** is simpler — the CMake/MSVC pipeline already works on the host
> - **Docker-build** is more portable but requires Visual Studio Build Tools in the Dockerfile (~10GB image)
> - **Recommendation:** Start with host-build + copy

### Startup Sequence

```
1. Host: Create RAM disk (imdisk) + VHD → R: and S:
2. Host: robocopy SSD backup → S: (restore latest data)
3. Host: docker-compose up
   a. MySQL container starts, bind-mounts S: as /var/lib/mysql
   b. realmd container starts, connects to MySQL
   c. mangosd container starts, connects to MySQL
4. Host: Periodic robocopy S: → SSD backup (every 15 min)
```

### Shutdown Sequence

```
1. WPF GUI catches SessionEnding (or user clicks Stop)
2. docker-compose down (clean MySQL shutdown)
3. robocopy S: → SSD backup (final sync)
4. diskpart: detach VHD from S:
5. imdisk: dismount RAM disk R:
```

---

## Phase 2: Distribution

### Config Externalization

Each component connects via environment variables or mounted config files:

| Component | Config Key | Purpose |
|-----------|-----------|---------|
| realmd | `LoginDatabaseInfo` | MySQL host:port |
| mangosd | `WorldDatabaseInfo` | MySQL host:port |
| mangosd | `CharacterDatabaseInfo` | MySQL host:port |
| mangosd | `RealmID` | Which realm entry in `realmlist` table |

This means:
- **mangosd on Machine B** connects to **MySQL on Machine A** via TCP
- **realmd on Machine C** connects to **MySQL on Machine A** via TCP
- The `realmlist` table in MySQL tells clients which world server IP to connect to

### Network Diagram (Multi-Machine)

```
Machine A (192.168.1.10)          Machine B (192.168.1.11)
┌──────────────────────┐          ┌──────────────────────┐
│ MySQL :3306          │◀────────│ mangosd :8085        │
│ realmd :3724         │         │ (bots, world logic)  │
│ RAM disk (S:) 8 GB   │         └──────────────────────┘
└──────────────────────┘
        ▲
        │              Machine C (192.168.1.12)
        │              ┌──────────────────────┐
        └──────────────│ mangosd :8085        │
                       │ (continent #2)       │
                       └──────────────────────┘
```

### Realistic Constraints for 1.12 CMaNGOS

- **MySQL** is the bottleneck — a single write-primary. Read replicas possible but mangosd typically expects one connection string.
- **mangosd** may not support map/continent splitting natively. This needs source code investigation.
- **realmd** is lightweight and stateless — easiest to scale horizontally.
- **Playerbots** run inside mangosd — scaling mangosd = scaling bots across instances.

---

## Phase 3: Kubernetes (Future Exploration)

```
┌─ Machine A ───────────────────────────────┐
│ MySQL StatefulSet (1 replica)              │
│   - hostPath volume → RAM disk or SSD      │
│   - ClusterIP Service :3306                │
└────────────────────────────────────────────┘

┌─ Machine A+B ─────────────────────────────┐
│ realmd Deployment (N replicas)             │
│   - LoadBalancer Service :3724             │
│   - HPA based on connection count          │
└────────────────────────────────────────────┘

┌─ Machine C,D,E ───────────────────────────┐
│ mangosd StatefulSet (1 per map shard)      │
│   - Each pod handles specific maps         │
│   - ClusterIP Service per pod              │
│   - Config: RealmID per shard              │
└────────────────────────────────────────────┘
```

> **Note:** K8s is aspirational at this stage. The immediate goal is Docker Compose on a single machine.

---

## RAM Disk Manager — GUI Application

The GUI manages two independent layers:

### Layer 1: Host RAM Disk
- Create/destroy ImDisk RAM disk + VHD
- Sync VHD ↔ SSD (robocopy)
- Status: mounted? size used? last sync result?
- Auto-shutdown: catches Windows shutdown, flushes + syncs + detaches

### Layer 2: Docker Services
- `docker-compose up` / `docker-compose down`
- Container status: running, stopped, health checks
- Container logs (optional streaming)

### GUI Layout (Conceptual)

```
┌──────────────────────────────────────────────────────┐
│  WoW Server Manager                        [_] [□] [X]│
├──────────────────────────────────────────────────────┤
│                                                        │
│  ┌─ HOST ──────────────────────────────────────────┐  │
│  │ RAM Disk (R:)   ● ONLINE   4 GB   62% free      │  │
│  │ VHD (S:)        ● ONLINE   3 GB   mysql-data.vhd│  │
│  │ Last Sync       2 min ago  (OK)                 │  │
│  └─────────────────────────────────────────────────┘  │
│                                                        │
│  ┌─ DOCKER ────────────────────────────────────────┐  │
│  │ mysql           ● RUNNING  0d 1h 23m  :3306     │  │
│  │ realmd          ● RUNNING  0d 1h 23m  :3724     │  │
│  │ mangosd         ● RUNNING  0d 1h 23m  :8085     │  │
│  │ bots connected  50/50                           │  │
│  └─────────────────────────────────────────────────┘  │
│                                                        │
│  [▶ Start All] [■ Stop All] [↻ Sync Now]              │
│  [▶ Start RAM] [▶ Start DB] [▶ Start Server]          │
│                                                        │
│  ═══════════════════════════════════════════════════   │
│  LOG                                          [Clear] │
│  14:32:01  Auto-synced to SSD (exit 0)                │
│  14:17:01  Auto-synced to SSD (exit 0)                │
│  14:02:00  Docker: containers healthy                 │
│  13:45:00  Server started — 50 bots connected         │
└──────────────────────────────────────────────────────┘
```

### Tech Stack
- **GUI:** PowerShell + WPF (zero dependencies — WPF is part of .NET Framework on all Windows 10/11 installs)
- **Backend:** `ramdisk-core.psm1` PowerShell module
- **Container orchestration:** Calls `docker-compose` CLI
- **Status polling:** Every 8 seconds via `DispatcherTimer`
- **Shutdown safety:** WPF `SessionEnding` event + Task Scheduler event trigger as backup

---

## Auto-Shutdown — Multi-Layer Defense

Three layers ensure MySQL data is synced to SSD before the RAM disk disappears:

| Layer | Mechanism | Trigger | Reliability |
|-------|-----------|---------|-------------|
| 1. WPF `SessionEnding` | GUI app catches Windows shutdown, cancels briefly, does fast sync | User shutdown/reboot while GUI is running | ★★★ Primary |
| 2. Task Scheduler event | Triggers on `User32/EventID 1074`, runs `shutdown-sync.ps1` | Any system shutdown | ★★ Backup |
| 3. Manual Stop button | User clicks Stop → full clean flush → sync → detach | User-initiated | ★★★ Gold standard |

Layer 1 is the primary defense: the GUI app is expected to always be running when the server is up.

---

## Implementation Order

| Step | What | Deliverable |
|------|------|-------------|
| **1. Docker Compose** | Dockerfiles for realmd + mangosd, docker-compose.yml, test with RAM disk bind mount | Working `docker-compose up` |
| **2. Core Module** | Refactor 6 scripts into `ramdisk-core.psm1` | Clean PowerShell module |
| **3. GUI App** | WPF desktop application managing RAM + Docker | `ramdisk-ui.ps1` |
| **4. Auto-Shutdown** | SessionEnding handler + Task Scheduler event trigger | Data-safe reboots |

---

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| RAM disk approach | Host ImDisk + VHD, Docker bind-mount | VHD gives NTFS that MySQL needs; syncable to SSD; survives container restart |
| Container granularity | 3 separate images (mysql, realmd, mangosd) | Independent scaling; can move to different machines |
| DB container | Official `mysql:8.0` image | Don't reinvent MySQL container; just bind-mount the data dir |
| Game server images | Custom Dockerfiles | Need to build from mangos-classic source with playerbots |
| Config management | Bind-mounted config files from host | Easy to edit; survives container rebuilds |
| Map data | Bind-mounted from host (`mangos-install/data`) | Maps/DBC/VMaps are large and read-only; no need to copy into image |
| Orchestration | Docker Compose now, K8s later | Compose is sufficient for single-machine; K8s manifests for distribution |
| GUI tech | PowerShell WPF | Zero dependencies; already on every Windows machine |

---

## Open Questions

1. **Container build strategy:** Build realmd/mangosd inside Docker (multi-stage with MSVC Build Tools, ~10GB image) or build on host and copy binaries into a thin runtime image?
   - Host-build + copy is simpler (build pipeline already works)
   - Docker-build is more portable but complex
   - **Leaning:** Start with host-build + copy

2. **Map/continent splitting:** Does CMaNGOS Classic support running multiple world servers, each handling different maps? This determines whether scaling mangosd horizontally is even possible.

3. **RAM disk size:** Currently 4GB. For Docker overhead + future bot scaling, consider 8GB.

4. **Playerbots in containers:** Playerbot characters are stored in the `characters` database (MySQL). When mangosd scales horizontally, bot characters would need to be distributed across instances or share the same database. How should bot assignment work across multiple world server instances?
