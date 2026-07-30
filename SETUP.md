# Vanilla WoW 1.12 Private Server — Complete Setup Guide

This guide covers setting up a **World of Warcraft Classic 1.12 (Vanilla)** private server using
**CMaNGOS** with AI **Playerbots** on Windows. Every step is documented for a fresh machine
with no prior setup. Includes all known pitfalls, workarounds, and fixes.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Install Tools](#2-install-tools)
3. [Prepare Source Code](#3-prepare-source-code)
4. [Build Workarounds (Critical)](#4-build-workarounds-critical)
5. [Set Up MySQL Databases](#5-set-up-mysql-databases)
6. [Build the Server](#6-build-the-server)
7. [Extract Client Data (Maps, DBC)](#7-extract-client-data-maps-dbc)
8. [Configure the Server](#8-configure-the-server)
9. [Startup & Shutdown](#9-startup--shutdown)
10. [Create Accounts](#10-create-accounts)
11. [Connect Your WoW Client](#11-connect-your-wow-client)
12. [Playing with Bots](#12-playing-with-bots)
13. [Troubleshooting](#13-troubleshooting)
14. [Reference](#14-reference)

---

## 1. Prerequisites

| Item | Required Version | Download From |
|---|---|---|
| **Visual Studio** | 2022+ (2026 tested) | https://visualstudio.microsoft.com/downloads/ |
| **C++ Workload** | "Desktop development with C++" | Install via VS Installer → Modify |
| **CMake** | 3.16+ (4.4.0 tested) | https://cmake.org/download/ |
| **MySQL Server** | 8.x | https://dev.mysql.com/downloads/installer/ |
| **Git for Windows** | 2.x (provides Git Bash) | https://git-scm.com/download/win |
| **Boost C++ Libraries** | 1.86.0 pre-built for MSVC 14.3 | https://sourceforge.net/projects/boost/files/boost-binaries/1.86.0/ |
| **WoW 1.12 Client** | 1.12.1 (build 5875) or 1.12.2/1.12.3 | Legally acquired copy |

**Disk space needed:** ~30 GB (source + build + databases + client data)

---

## 2. Install Tools

### 2a. Visual Studio + C++ Workload
1. Download and run the VS installer
2. Under **Workloads**, check **"Desktop development with C++"**
3. Click **Install** — downloads ~5 GB, takes 10-15 minutes
4. Verify: `cl.exe` should be found under `C:\Program Files\Microsoft Visual Studio\<version>\Community\VC\Tools\MSVC\`

### 2b. CMake
1. Download the `.msi` installer
2. Check **"Add CMake to the system PATH"** during install
3. Verify: `cmake --version`

### 2c. MySQL Server 8.x
1. Download MySQL Installer
2. Choose **Server Only** (Developer Default also works)
3. Set root password — **remember it** (this guide uses `YOUR_MYSQL_ROOT_PASSWORD` as example)
4. Default port: `3306`
5. Verify: `Get-Service MySQL80` shows **Running**

### 2d. Git for Windows
1. Accept defaults — Git Bash is needed for shell scripts
2. Verify: `git --version`

### 2e. Boost 1.86.0
1. Download `boost_1_86_0-msvc-14.3-64.exe` from SourceForge
2. Install to **`C:\local\boost_1_86_0`**
3. Set environment variable (PowerShell as Administrator):
   ```powershell
   [Environment]::SetEnvironmentVariable("BOOST_ROOT", "C:\local\boost_1_86_0", "User")
   ```

> **Why pre-built?** Building Boost from source takes 30+ minutes and requires additional tooling. The pre-built MSVC 14.3 binaries are ABI-compatible with VS 2022/2026.

---

## 3. Prepare Source Code

Directory layout:
```
D:\code\wow-server\
├── mangos-classic\          # CMaNGOS server core
│   └── src\modules\PlayerBots\  # Playerbots module
├── classic-db\              # World content database
└── mangos-install\          # Final install directory (created during build)
```

### 3a. Place CMaNGOS Classic source
Extract CMaNGOS source to `D:\code\wow-server\mangos-classic\`

### 3b. Place classic-db
Extract classic-db to `D:\code\wow-server\classic-db\`

### 3c. Clone Playerbots module
```powershell
mkdir D:\code\wow-server\mangos-classic\src\modules
git clone https://github.com/haihengh/playerbots.git D:\code\wow-server\mangos-classic\src\modules\PlayerBots --depth 1
```

> **Why?** CMaNGOS includes FetchContent for playerbots, but pre-cloning gives us access to the SQL files and avoids CMake fetch issues.

---

## 4. Build Workarounds (Critical)

These fixes are **required** to build with the pre-built Boost 1.86.0 and CMake 4.x. Skip any of these and the build will fail.

### 4a. Fix FindBoost.cmake path (CMake 4.x compat)
CMake 4.x removed the built-in `FindBoost.cmake`. CMaNGOS ships a custom one but in a subdirectory where CMake can't find it:
```powershell
copy D:\code\wow-server\mangos-classic\cmake\macros\FindBoost\FindBoost.cmake `
     D:\code\wow-server\mangos-classic\cmake\macros\FindBoost.cmake
```

### 4b. Fix Boost library naming (lib prefix)
The pre-built Boost names libraries as `boost_*.lib` but the CMaNGOS linker expects `libboost_*.lib`:
```powershell
cd C:\local\boost_1_86_0\lib64-msvc-14.3
Get-ChildItem boost_*.lib | ForEach-Object { Copy-Item $_.FullName ("lib" + $_.Name) }
```

### 4c. Add boost::throw_exception stub
Boost 1.86.0 split `throw_exception` into its own library which the pre-built package doesn't include. Create this file at `D:\code\wow-server\mangos-classic\src\shared\boost_throw_exception_stub.cpp`:

```cpp
// Stub for boost::throw_exception missing from pre-built Boost 1.86.0
// Undefine BOOST_ALL_DYN_LINK so symbols are defined locally, not dllimport
#ifdef BOOST_ALL_DYN_LINK
#  undef BOOST_ALL_DYN_LINK
#endif

#include <boost/throw_exception.hpp>
#include <stdexcept>

namespace boost {

BOOST_NORETURN void throw_exception(std::exception const& e)
{
    throw e;
}

BOOST_NORETURN void throw_exception(std::exception const& e, boost::source_location const& loc)
{
    throw e;
}

} // namespace boost
```

Then register it in `D:\code\wow-server\mangos-classic\src\shared\CMakeLists.txt`:

Find the `set(LIBRARY_SRCS` block and add after `SystemConfig.h`:
```cmake
    # Stub for boost::throw_exception missing from pre-built Boost 1.86 binaries
    boost_throw_exception_stub.cpp
```

### 4d. Fix MMAP crash (MoveMap.cpp & ObjectMgr.cpp)
When `mmap.enabled = 0`, certain code paths still try to load navmesh data and crash with `MANGOS_ASSERT` failures. Three fixes are needed:

**MoveMap.cpp** (line 202) — Change the assertion to a safe return:
```cpp
// Original:
MANGOS_ASSERT(itr != loadedMMaps.end());
// Replace with:
if (itr == loadedMMaps.end())
    return false; // MMap not loaded (e.g. mmaps disabled)
```

**ObjectMgr.cpp** (lines 6067, 6094) — Guard `loadMapInstance` with `IsEnabled()`:
```cpp
// Original:
MMAP::MMapFactory::createOrGetMMapManager()->loadMapInstance(sWorld.GetDataPath(), creature.mapid, 0);
// Replace with:
if (MMAP::MMapFactory::createOrGetMMapManager()->IsEnabled())
    MMAP::MMapFactory::createOrGetMMapManager()->loadMapInstance(sWorld.GetDataPath(), creature.mapid, 0);
```
Do the same for the gameobject version a few lines below.

**GridMap.cpp** (line 1294) — Add `IsEnabled()` check:
```cpp
// Original:
if (!MMAP::MMapFactory::createOrGetMMapManager()->IsMMapIsLoaded(m_mapId, x, y))
// Replace with:
if (!MMAP::MMapFactory::createOrGetMMapManager()->IsMMapIsLoaded(m_mapId, x, y) && MMAP::MMapFactory::createOrGetMMapManager()->IsEnabled())
```

---

## 5. Set Up MySQL Databases

All commands use the MySQL command-line client. Replace `YOUR_MYSQL_ROOT_PASSWORD` with your root password.

```powershell
$mysql = "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"
$pass = "YOUR_MYSQL_ROOT_PASSWORD"   # YOUR MySQL root password
```

### 5a. Create databases and user
```sql
CREATE DATABASE IF NOT EXISTS classicmangos DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS classiccharacters DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS classicrealmd DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS classiclogs DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;

CREATE USER IF NOT EXISTS 'mangos'@'localhost' IDENTIFIED BY 'mangos';
GRANT ALL PRIVILEGES ON classicmangos.* TO 'mangos'@'localhost';
GRANT ALL PRIVILEGES ON classiccharacters.* TO 'mangos'@'localhost';
GRANT ALL PRIVILEGES ON classicrealmd.* TO 'mangos'@'localhost';
GRANT ALL PRIVILEGES ON classiclogs.* TO 'mangos'@'localhost';
FLUSH PRIVILEGES;
```

Run from PowerShell:
```powershell
& $mysql -u root -p"$pass" -e "CREATE DATABASE IF NOT EXISTS classicmangos ..."
# (run each CREATE/GRANT statement above)
```

### 5b. Import base server schemas
```powershell
$base = "D:\code\wow-server\mangos-classic\sql\base"
& $mysql -u root -p"$pass" classicmangos < "$base\mangos.sql"
& $mysql -u root -p"$pass" classiccharacters < "$base\characters.sql"
& $mysql -u root -p"$pass" classicrealmd < "$base\realmd.sql"
& $mysql -u root -p"$pass" classiclogs < "$base\logs.sql"
```

### 5c. Import world content from classic-db
```powershell
cd D:\code\wow-server\classic-db
# Decompress the full dump (Git Bash has gzip, or use 7-Zip)
gzip -kdf "Full_DB\ClassicDB_1_12_1_z2815.sql.gz"

# Import (takes a few minutes)
& $mysql -u root -p"$pass" classicmangos < "Full_DB\ClassicDB_1_12_1_z2815.sql"
```

### 5d. Import ACID creature AI
```powershell
& $mysql -u root -p"$pass" classicmangos < "D:\code\wow-server\classic-db\ACID\acid_classic.sql"
```

### 5e. Import Playerbots SQL
```powershell
$pb = "D:\code\wow-server\mangos-classic\src\modules\PlayerBots\sql"

# World tables (base)
& $mysql -u root -p"$pass" classicmangos -e "SOURCE $pb/world/ai_playerbot_indexes.sql"
& $mysql -u root -p"$pass" classicmangos -e "SOURCE $pb/world/ai_playerbot_rpg_races.sql"
& $mysql -u root -p"$pass" classicmangos -e "SOURCE $pb/world/ai_playerbot_texts.sql"

# World tables (classic/vanilla-specific)
foreach ($f in Get-ChildItem "$pb\world\classic\*.sql") {
    & $mysql -u root -p"$pass" classicmangos -e "SOURCE $($f.FullName -replace '\\','/')"
}

# Character tables
foreach ($f in Get-ChildItem "$pb\characters\*.sql") {
    & $mysql -u root -p"$pass" classiccharacters -e "SOURCE $($f.FullName -replace '\\','/')"
}
```

### 5f. Apply world DB updates (z2816 → z2830)
The classic-db is at version z2815 but the server expects z2830:
```powershell
$updates = "D:\code\wow-server\mangos-classic\sql\updates\mangos"
$versions = @("z2816", "z2817", "z2818", "z2821", "z2822", "z2823",
              "z2824", "z2825", "z2826", "z2827", "z2828", "z2829", "z2830")
foreach ($v in $versions) {
    $file = Get-ChildItem "$updates\$($v)_*.sql" | Select-Object -First 1
    if ($file) {
        Write-Host "Applying $($file.Name)..."
        & $mysql -u root -p"$pass" classicmangos < $file.FullName
    }
}
```

---

## 6. Build the Server

### 6a. Configure with CMake
```powershell
cd D:\code\wow-server\mangos-classic
mkdir build
cd build

cmake .. -G "Visual Studio 18 2026" -A x64 `
  -DCMAKE_INSTALL_PREFIX="D:\code\wow-server\mangos-install" `
  -DBUILD_PLAYERBOTS=ON `
  -DBUILD_EXTRACTORS=ON `
  -DBOOST_ROOT="C:\local\boost_1_86_0" `
  -DBoost_USE_STATIC_LIBS=OFF `
  -DBoost_USE_STATIC_RUNTIME=OFF `
  '-DCMAKE_CXX_FLAGS=/DBOOST_ALL_DYN_LINK' `
  '-DCMAKE_EXE_LINKER_FLAGS=/LIBPATH:C:\local\boost_1_86_0\lib64-msvc-14.3'
```

> **Why `Boost_USE_STATIC_LIBS=OFF`?** The pre-built package contains DLL import libs, not true static libs.

> **Why `BOOST_ALL_DYN_LINK`?** Tells the compiler that Boost symbols come from DLLs (`__declspec(dllimport)`). Without this, data symbols like `boost::program_options::arg` are unresolved at link time.

> **Why `/LIBPATH`?** Adds the Boost library directory to the linker search path. Needed because Boost's auto-link pragma generates bare library names without full paths.

Expected output: `-- Build files have been written to: .../build`

### 6b. Compile
```powershell
cmake --build . --config Release -j 6
```
Takes 15-30 minutes. Successful output includes:
- `realmd.exe` — login/auth server
- `mangosd.exe` — world/game server (with playerbots)
- `ad.exe` — map/DBC extractor
- `vmap_extractor.exe`, `vmap_assembler.exe` — vmap tools
- `MoveMapGen.exe` — navigation mesh generator

### 6c. Install
```powershell
cmake --install . --config Release
```

### 6d. Copy required DLLs
```powershell
Copy-Item "C:\local\boost_1_86_0\lib64-msvc-14.3\*.dll" "D:\code\wow-server\mangos-install\"
```

The install directory now contains all executables, config templates, and required DLLs.

---

## 7. Extract Client Data (Maps, DBC, VMaps, MMaps)

You need your WoW 1.12 client. This guide assumes:
- WoW client at `C:\World of Warcraft Classic`
- Server install at `C:\code\wow-server\wow-server\mangos-install`
- Platform: Windows with PowerShell / Git Bash

| Data | Tool | Time | Size | Required? |
|---|---|---|---|---|
| **Maps** | `ad.exe` | ~15 min | ~1 GB | Yes — server won't load without them |
| **DBC** | `ad.exe` | (included) | ~50 MB | Yes — client database files |
| **VMaps** | `vmap_extractor` + `vmap_assembler` | ~30 min | ~300 MB | Strongly recommended — line-of-sight, height, indoor/outdoor |
| **MMaps** | `MoveMapGen.exe` | 1–2 hours | ~2 GB | Recommended — full bot pathfinding navigation mesh |

### 7a. One-shot extraction script (PowerShell)

Copy all four extractors to the WoW directory and run everything in sequence:

```powershell
$WoW = "C:\World of Warcraft Classic"
$Tools = "C:\code\wow-server\wow-server\mangos-install\tools"
$Install = "C:\code\wow-server\wow-server\mangos-install"

# Copy extractors to WoW directory
Copy-Item "$Tools\ad.exe", "$Tools\vmap_extractor.exe", "$Tools\vmap_assembler.exe" $WoW

# Step 1: Maps + DBC (~15 min)
Write-Host "=== Extracting Maps + DBC ===" -ForegroundColor Green
Push-Location $WoW
.\ad.exe
Pop-Location

# Copy to install
Copy-Item -Recurse "$WoW\maps" $Install
Copy-Item -Recurse "$WoW\dbc" $Install
Write-Host "Maps + DBC done." -ForegroundColor Green

# Step 2: VMaps (~30 min)
Write-Host "=== Extracting VMaps ===" -ForegroundColor Green
Push-Location $WoW
.\vmap_extractor.exe
# Output dir must exist before assembly
New-Item -ItemType Directory -Force -Path "$WoW\vmaps" | Out-Null
.\vmap_assembler.exe Buildings vmaps
Pop-Location

Copy-Item -Recurse "$WoW\vmaps" $Install
Write-Host "VMaps done." -ForegroundColor Green

# Step 3: MMaps (~1-2 hours) — requires maps + vmaps already in install dir
Write-Host "=== Generating MMaps (1-2 hours) ===" -ForegroundColor Green
Push-Location $Install
.\tools\MoveMapGen.exe
Pop-Location
Write-Host "All client data extracted." -ForegroundColor Green
```

### 7b. One-shot extraction script (Git Bash)

```bash
WOW="/c/World of Warcraft Classic"
TOOLS="C:/code/wow-server/wow-server/mangos-install/tools"
INSTALL="C:/code/wow-server/wow-server/mangos-install"

# Copy extractors
cp "$TOOLS/ad.exe" "$TOOLS/vmap_extractor.exe" "$TOOLS/vmap_assembler.exe" "$WOW/"

# Step 1: Maps + DBC (~15 min)
echo "=== Extracting Maps + DBC ==="
cd "$WOW" && ./ad.exe
cp -r "$WOW/maps" "$WOW/dbc" "$INSTALL/"
echo "Maps + DBC done."

# Step 2: VMaps (~30 min)
echo "=== Extracting VMaps ==="
cd "$WOW" && ./vmap_extractor.exe
mkdir -p "$WOW/vmaps"
./vmap_assembler.exe Buildings vmaps
cp -r "$WOW/vmaps" "$INSTALL/"
echo "VMaps done."

# Step 3: MMaps (~1-2 hours)
echo "=== Generating MMaps (1-2 hours) ==="
cd "$INSTALL" && ./tools/MoveMapGen.exe
echo "All client data extracted."
```

### 7c. Enable pathfinding in config

After extraction, enable VMaps and MMaps in `mangosd.conf`:

```
vmap.enableLOS = 1
vmap.enableHeight = 1
vmap.enableIndoorCheck = 1
mmap.enabled = 1
```

If you skip VMaps/MMaps, keep them disabled and create empty directories to prevent crashes:

```powershell
New-Item -ItemType Directory -Force -Path "$Install\vmaps", "$Install\mmaps"
```

---

## 8. Configure the Server

### 8a. Create config files
```powershell
cd D:\code\wow-server\mangos-install
copy mangosd.conf.dist mangosd.conf
copy realmd.conf.dist realmd.conf
copy aiplayerbot.conf.dist aiplayerbot.conf
```

### 8b. Verify database settings
The defaults match our setup. In `mangosd.conf`:
```
WorldDatabaseInfo     = "127.0.0.1;3306;mangos;mangos;classicmangos"
CharacterDatabaseInfo = "127.0.0.1;3306;mangos;mangos;classiccharacters"
LoginDatabaseInfo     = "127.0.0.1;3306;mangos;mangos;classicrealmd"
DataDir = "."
```

In `realmd.conf`:
```
LoginDatabaseInfo = "127.0.0.1;3306;mangos;mangos;classicrealmd"
```

### 8c. Disable VMap/MMap (if not extracted)
In `mangosd.conf`:
```
vmap.enableLOS = 0
vmap.enableHeight = 0
vmap.enableIndoorCheck = 0
mmap.enabled = 0
```

### 8d. Configure playerbots
In `aiplayerbot.conf`:
```
AiPlayerbot.Enabled = 1
AiPlayerbot.RandomBotAutologin = 1        # Bots automatically join the world
AiPlayerbot.RandomBotLoginAtStartup = 1   # Bots log in on server start
AiPlayerbot.MinRandomBots = 50            # Minimum random bots online
AiPlayerbot.MaxRandomBots = 50            # Maximum random bots online
AiPlayerbot.DeleteRandomBotAccounts = 0   # Set to 1 to reset all bots
```

- **For first launch:** Set bot count to 50 to test stability
- **For populated world:** Increase to 200-500 depending on system specs
- **Performance:** Each ~100 bots adds roughly 10-20ms to the tick loop

> **Recommended:** Start with 50 bots to verify stability. The initial bot account creation takes extra time on first launch. If the server crashes silently, reduce bot count.

### 8e. Suppress spammy logs
To reduce console spam, edit `mangosd.conf`:
```
LogFileLevel = 1          # Only errors to file
LogLevel = 1              # Only errors to console
```

---

## 9. Startup & Shutdown

This section covers both **disk-based MySQL** and **RAM disk MySQL** (section 15d).
If you haven't set up the RAM disk yet, skip the RAM disk steps — the server works
fine from SSD alone.

---

### 9a. Startup (RAM Disk Users)

If you set up the RAM disk (section 15d), the Task Scheduler auto-creates it on boot.
**Always verify the RAM disk is ready before starting the game servers:**

```powershell
# Check S: exists and has MySQL data
Test-Path S:\ibdata1
# Should return: True
```

If the RAM disk didn't auto-start (or you rebooted and it's missing), start it manually
as **Administrator**:

```powershell
PowerShell -ExecutionPolicy Bypass -File "D:\code\wow-server\ramdisk\3-start-ramdisk.ps1"
```

Once `S:\ibdata1` exists, proceed to section 9c.

---

### 9b. Startup (Disk-Based MySQL — No RAM Disk)

If you're running MySQL directly on the SSD (no RAM disk), just make sure MySQL is running:

```powershell
Get-Service MySQL80 | Select-Object Status
# Should show: Running

# If Stopped:
Start-Service MySQL80
```

---

### 9c. Start the Game Servers

**Both servers must run simultaneously** — use **two separate** terminal windows.

**⚠️ Order matters: realmd first, then mangosd.**

#### Terminal 1 — Auth Server (realmd):

```powershell
cd D:\code\wow-server\mangos-install
.\realmd.exe
```

Expected: shows `[CMaNGOS Auth server v0.18] port(3724)` then waits quietly.

#### Terminal 2 — World Server (mangosd):

```powershell
cd D:\code\wow-server\mangos-install
.\mangosd.exe
```

Expected: loads for 2-4 minutes then shows `CMANGOS: World initialized` and
displays the `mangos>` prompt. If bots are enabled, they'll begin logging in.

**Healthy server indicators:**
- `Avg Diff: ~50-80` — tick loop at target speed
- `Max Diff: < 500` — no major lag spikes
- `Sessions online: 0` (until you log in, then shows your session + bots)
- No `Critical Error` or `MANGOS_ASSERT` messages

---

### 9d. Shutdown

> **🔥 Critical (RAM Disk users):** If you shut down or restart without running
> `shutdown-sync.ps1`, you **will lose** up to 15 minutes of database changes
> (character progress, items, quests, etc.). The live data is on a RAM disk —
> it vanishes when power is lost. See section 15d for details.

**Correct shutdown order:**

```
Step 1:  Ctrl+C in mangosd terminal  →  server saves character data to MySQL
Step 2:  Ctrl+C in realmd terminal   →  auth server shuts down
Step 3:  shutdown-sync.ps1 (Admin)   →  stop MySQL → sync RAM → SSD
```

#### Step 1 — Stop mangosd

In the mangosd terminal window, press **`Ctrl+C`**. The server will:
- Kick all online players and bots
- Save character states, guild data, and world state to MySQL
- Close gracefully

Wait for the process to exit fully (the prompt returns).

> **Why Ctrl+C FIRST:** The game server must save data to MySQL before MySQL is
> stopped. If you stop MySQL first, mangosd's final writes fail silently and
> character progress is lost.

#### Step 2 — Stop realmd

In the realmd terminal window, press **`Ctrl+C`**. Auth server exits immediately —
no data to flush.

#### Step 3 — Sync RAM disk to SSD (RAM Disk users only)

Run as **Administrator**:

```powershell
PowerShell -ExecutionPolicy Bypass -File "D:\code\wow-server\ramdisk\shutdown-sync.ps1"
```

What it does:
1. Forces InnoDB to flush all dirty pages to disk
2. Stops MySQL cleanly (waits up to 120 seconds)
3. Robocopies `S:\` (VHD on RAM) → `D:\code\wow-server\mysql-data-backup\` (SSD)
4. Shows sync summary (files/dirs/bytes copied)
5. Verifies `ibdata1` is present in backup
6. Detaches VHD and dismounts RAM disk

**Verify success** — look for these lines in the output:
```
  Files :       822        77       745         0         0        43
  Bytes :  946.80 m  378.68 m  568.11 m         0         0  109.65 m
  ibdata1: XX MB - OK
=== Shutdown complete. Data safe on SSD. ===
```

If you see `Robocopy exit code: 8` or higher, **the sync failed** — do not reboot
until you've resolved the issue, or data will be lost.

#### Step 4 — Done

It's now safe to shut down or restart Windows. On next boot, the RAM disk will
auto-restore from the SSD backup and data will be current.

---

### Quick Reference

| Scenario | Steps |
|---|---|
| **Fresh boot, RAM disk** | Boot → wait for auto-task → `realmd.exe` → `mangosd.exe` |
| **Fresh boot, no RAM disk** | Boot → `realmd.exe` → `mangosd.exe` |
| **Shutdown, RAM disk** | Ctrl+C mangosd → Ctrl+C realmd → `shutdown-sync.ps1` (Admin) |
| **Shutdown, no RAM disk** | Ctrl+C mangosd → Ctrl+C realmd |
| **Restart mangosd only** | Ctrl+C mangosd → `.\mangosd.exe` (realmd can stay running) |
| **RAM disk not auto-started** | Run `3-start-ramdisk.ps1` as Admin, then proceed |

---

## 10. Create Accounts

### Method 1: Via mangosd console (recommended)
Type directly in the mangosd window:
```
account create <username> <password>
account set gmlevel <username> 3
```
Example: `account create myuser mypassword`

The server handles SRP6 password hashing automatically.

### Method 2: Via database (for automation)
```sql
INSERT INTO classicrealmd.account (username, gmlevel, sessionkey, v, s, email, joindate, lockedIp, failed_logins, locked, active_realm_id, expansion, mutetime, locale, os, platform)
VALUES ('username', 3, NULL, NULL, NULL, NULL, NOW(), '0.0.0.0', 0, 0, 0, 0, 0, '', '', '');
```
Then immediately create the account via mangosd console (`account create <user> <pass>`) to set the proper SRP6 password verifier. Direct SQL inserts don't set the password.

---

## 11. Connect Your WoW Client

### 11a. Set the realmlist
Edit `C:\World of Warcraft Classic\realmlist.wtf`:
```
set realmlist 127.0.0.1
```

### 11b. Windowed mode (fixes blank screen on alt-tab)
Edit `C:\World of Warcraft Classic\WTF\Config.wtf` and add:
```
SET gxWindow "1"
```
Or launch with: `WoW.exe -windowed`

### 11c. Login
1. Launch `WoW.exe`
2. Username: the account you created
3. Password: the password you set
4. Realm list should show **"MaNGOS"** — select it
5. Create a character and enter the world

---

## 12. Playing with Bots

### Basic commands
| Command | Description |
|---|---|
| `.bot add mage` | Add a mage bot to your party |
| `.bot add warrior` | Add a warrior bot |
| `.bot add priest` | Add a priest bot |
| `.bot add <any class>` | Add any class bot |
| `.bot remove <name>` | Remove/kick a bot from party |
| `.bot co <name> follow` | Bot follows you |
| `.bot co <name> stay` | Bot stays in place |
| `.bot co <name> combat` | Bot enters combat mode |
| `.bot co <name> heal` | Bot heals (priest/druid/shaman/paladin) |
| `.bot co <name> tank` | Bot tanks |
| `.bot stats` | View bot statistics |

### Useful GM commands
| Command | Description |
|---|---|
| `.gm on` | Enable GM mode |
| `.levelup 60` | Level to 60 |
| `.additem <id>` | Add item by ID |
| `.modify money 999999` | Add gold |
| `.tele <location>` | Teleport (e.g., `.tele stormwind`) |
| `.announce <msg>` | Server-wide announcement |

Full bot command reference: https://github.com/haihengh/playerbots

---

## 13. Troubleshooting

### Build Errors

| Error | Fix |
|---|---|
| `cmake: FindBoost.cmake not found` | Run step 4a — copy FindBoost.cmake up one level |
| `LNK1104: cannot open libboost_*.lib` | Run step 4b — create lib-prefixed copies |
| `LNK2019: unresolved throw_exception` | Run step 4c — create the stub file and register it |
| `LNK2019: unresolved program_options::arg` | Add `-DBOOST_ALL_DYN_LINK` to CMake flags |
| `BoostConfig.cmake version unknown` | Boost installation is incomplete or wrong version |

### Runtime Errors

| Error | Fix |
|---|---|
| `database is out of date (z2815 vs z2830)` | Run step 5f — apply DB updates |
| `VMap file missing or points to wrong version` | Run step 7c — create empty vmaps/mmaps dirs, disable in config |
| `MANGOS_ASSERT: MMAP::loadMap()` | Run step 4d — apply MMAP guard fixes |
| `Critical Error: itr != loadedMMaps.end()` | Same as above — step 4d |
| Server starts then exits silently | Reduce bot count to 50, ensure `mmap.enabled = 0` |
| `VMAP height use disabled! Creatures in broken state` | Expected with VMaps off — creatures use basic pathfinding, works fine |

### Connection Issues

| Issue | Fix |
|---|---|
| "Unable to connect" in client | Both `realmd.exe` AND `mangosd.exe` must be running |
| Blank/black screen on alt-tab | Add `SET gxWindow "1"` to Config.wtf or use `-windowed` flag |
| "Account already exists" | Delete with `account delete <user>` in mangosd console, then recreate |
| Login fails with correct password | Account was created via SQL without SRP6 — recreate via mangosd console |

### Playerbots Issues

| Issue | Fix |
|---|---|
| 0 bots online | Check `RandomBotAutologin = 1` and `RandomBotLoginAtStartup = 1` |
| Server crashes with many bots | Reduce `MinRandomBots`/`MaxRandomBots` to 50, test, then increase |
| Bots spam abilities | Known quirk — `AddCooldown` spam is harmless |
| Bot creation takes forever | Normal on first launch; `PreQuests = 0` speeds it up |
| `No random guilds available` spam | Set `RandomBotGuildCount = 50` in aiplayerbot.conf |
| `AddCooldown> already existing cooldown` | CMaNGOS quirk — harmless at any scale |
| MySQL fails to start after config change | Check error log; `innodb_flush_method = async` is Linux-only (use `normal` on Windows) |
| MySQL `skip-log-bin` causes start failure | Remove old binlog index files from data directory, then restart |

---

## 14. Reference

### Default Ports
| Service | Port |
|---|---|
| MySQL | 3306 |
| Auth Server (realmd) | 3724 |
| World Server (mangosd) | 8085 |
| SOAP/Remote Access | 7878 |

### Database Summary
| Database | User | Password | Contents |
|---|---|---|---|
| classicmangos | mangos | mangos | World content, creatures, quests, items, ACID AI |
| classiccharacters | mangos | mangos | Player characters, inventory, guilds, mail |
| classicrealmd | mangos | mangos | Accounts, realm list, bans |
| classiclogs | mangos | mangos | Server logs |

### Key Files
| File | Location | Purpose |
|---|---|---|
| `mangosd.conf` | `mangos-install\` | World server configuration |
| `realmd.conf` | `mangos-install\` | Auth server configuration |
| `aiplayerbot.conf` | `mangos-install\` | Playerbots settings |
| `maps\` | `mangos-install\` | Extracted map files (~2,400+ .map files) |
| `vmaps\` | `mangos-install\` | Extracted vmap files (~6,077 files) |
| `mmaps\` | `mangos-install\` | Generated navmesh files (~2,009 files) |
| `dbc\` | `mangos-install\` | Extracted DBC data files |
| `my.ini` | `wow-server\` | Tuned MySQL config (source of truth) |
| `mysql-data-backup\` | `wow-server\` | SSD backup for RAM disk sync |
| `ramdisk\` | `wow-server\` | RAM disk management scripts |
| `SETUP.md` | `wow-server\` | This document |

### Directory Layout After Setup
```
D:\code\wow-server\
├── mangos-classic\         # Source code
│   ├── src\modules\PlayerBots\
│   └── build\              # Build artifacts
├── classic-db\             # World content SQL
├── mangos-install\         # Installed server (RUN FROM HERE)
│   ├── mangosd.exe
│   ├── realmd.exe
│   ├── mangosd.conf
│   ├── realmd.conf
│   ├── aiplayerbot.conf
│   ├── maps\
│   ├── dbc\
│   ├── vmaps\              # Line-of-sight + building collision (6,077 files)
│   ├── mmaps\              # NavMesh pathfinding (2,009 files)
│   └── tools\
│       ├── ad.exe
│       ├── vmap_extractor.exe
│       ├── vmap_assembler.exe
│       └── MoveMapGen.exe
├── mysql-data-backup\      # SSD backup for RAM disk (synced every 15 min)
├── ramdisk\                # RAM disk management scripts
│   ├── 1-install-driver.ps1
│   ├── 2-prepare-backup.ps1
│   ├── 3-start-ramdisk.ps1
│   ├── 4-setup-tasks.ps1
│   ├── sync-to-disk.ps1
│   └── shutdown-sync.ps1
├── my.ini                  # Tuned MySQL config (datadir=R:/)
└── SETUP.md                # This guide

C:\local\boost_1_86_0\      # Boost libraries

C:\World of Warcraft Classic\  # WoW client
```

---

## 15. Performance Optimization

### 15a. VMaps & MMaps Extraction

VMaps provide line-of-sight and building collision. MMaps provide navmesh-based pathfinding.
Without them, creatures use basic waypoint movement and can shoot through walls.

**Prerequisites:** WoW 1.12 client at `C:\World of Warcraft Classic`, extractor tools built (step 6b).

#### Extract VMaps (~35 minutes total)

```powershell
# Step 1: Extract building models (~30 min)
cd "C:\World of Warcraft Classic"
D:\code\wow-server\mangos-install\tools\vmap_extractor.exe

# Step 2: Assemble VMaps (~5 min)
mkdir "C:\World of Warcraft Classic\vmaps"
D:\code\wow-server\mangos-install\tools\vmap_assembler.exe Buildings vmaps

# Step 3: Copy to server
rm -rf "D:\code\wow-server\mangos-install\vmaps"
cp -r "C:\World of Warcraft Classic\vmaps" "D:\code\wow-server\mangos-install\vmaps"
```

**Result:** 6,077 files (`.vmtree` + `.vmtile` files covering all maps)

#### Generate MMaps (~1-2 hours)

```powershell
cd D:\code\wow-server\mangos-install
.\tools\MoveMapGen.exe
```

Reads `maps/` and `vmaps/`, outputs navigation mesh tiles to `mmaps/`. The `offmesh.txt not found`
warning is expected — it's for optional custom off-mesh connections.

**Result:** 2,009 files (`.mmap` + `.mmtile` files)

#### Enable in mangosd.conf

```
vmap.enableLOS = 1
vmap.enableHeight = 1
vmap.enableIndoorCheck = 1
mmap.enabled = 1
```

**Warning:** The server will use more RAM with VMaps/MMaps enabled. With the default 128 MB
InnoDB buffer pool, ensure your system has adequate memory. See section 15c for MySQL tuning.

### 15b. Bot Scaling (2000 accounts, 1200 online)

Configuration tested at `D:\code\wow-server\mangos-install\aiplayerbot.conf`:

```
AiPlayerbot.DeleteRandomBotAccounts = 1    # Wipes old bots on restart
AiPlayerbot.RandomBotAccountCount = 2000    # Creates 2000 accounts (RNDBOT0-RNDBOT1999)
AiPlayerbot.RandomBotAutoCreate = 1         # Auto-create 9 chars per account
AiPlayerbot.MinRandomBots = 1200            # Keep 1200 bots online
AiPlayerbot.MaxRandomBots = 1200
AiPlayerbot.RandomBotMinLevel = 1
AiPlayerbot.RandomBotMaxLevel = 60          # Full level spread
AiPlayerbot.RandomBotAutologin = 1          # Auto-login bots
AiPlayerbot.RandomBotLoginAtStartup = 1     # Login wave at server start
AiPlayerbot.RandomBotJoinLfg = 0            # Disabled — overhead at scale
AiPlayerbot.RandomBotJoinBG = 0             # Disabled — overhead at scale
AiPlayerbot.RandomBotAutoJoinBG = 0
AiPlayerbot.RandomBotGuildCount = 0         # Set to 50+ to suppress "No random guilds" spam
```

**Expected log noise at 1200 bots (all harmless):**

| Message | Explanation |
|---------|-------------|
| `No random guilds available` | `RandomBotGuildCount = 0`, bots look for guilds to join |
| `Player::AddCooldown> Spell(...) already existing cooldown 0?` | CMaNGOS quirk — bots log in with cooldowns set |
| `Spell::EffectSchoolDMG: Spell ... not handled in BTAura` | Missing BT aura handler in this core version |
| `Creature/Pet/Player ... not moving but have spline movement enabled` | Entity has movement data but is idle |
| `AbstractPathMovementGenerator::Initialize Path empty` | MMap edge case, rare, single occurrences are fine |

**Scaling notes:**
- The server was previously capped at 50 bots due to crash issues
- With VMaps/MMaps enabled and MySQL tuned (section 15c), 1200 bots runs stably
- Bot login is progressive — the `Active Zone Players` counter climbs gradually
- At 1200 bots, Map 0 (Azeroth) shows ~450-500 active zone players out of 800-900 total

### 15c. MySQL InnoDB Tuning

The WoW server databases total ~550 MB. With 64 GB system RAM, the entire DB can be cached
in memory, eliminating read I/O entirely.

**Config file:** `C:\ProgramData\MySQL\MySQL Server 8.0\my.ini`

**Updated config is maintained at:** `D:\code\wow-server\my.ini`

| Setting | Default | Tuned | Rationale |
|---------|---------|-------|-----------|
| `innodb_buffer_pool_size` | 128M | **2G** | Cache entire 550 MB DB in RAM (~4x headroom) |
| `innodb_flush_log_at_trx_commit` | 1 | **0** | Flush log once/sec instead of per-commit — biggest I/O reduction |
| `innodb_log_buffer_size` | 16M | **128M** | Larger write buffer before disk flush |
| `innodb_flush_method` | (default) | **normal** | Windows-appropriate I/O method |
| `innodb_io_capacity` | 200 | **2000** | Higher background I/O throughput |
| `innodb_io_capacity_max` | — | **4000** | Max I/O under pressure |
| `innodb_max_dirty_pages_pct` | 75 | **90** | Keep more dirty pages in RAM, flush less frequently |
| `innodb_max_dirty_pages_pct_lwm` | 0 | **10** | Start gentle flushing at 10% dirty |
| `innodb_change_buffering` | none | **all** | Buffer inserts/updates/deletes to reduce random I/O |
| `max_connections` | 151 | **500** | Headroom for 1200 bots |
| `table_open_cache` | 4000 | **8000** | More open tables for bot query patterns |
| `skip-log-bin` | (binlog on) | **enabled** | Disable binary logs — no replication, ~40% write reduction |
| `slow-query-log` | 1 | **0** | Disable slow query logging |
| `general-log` | 0 | **0** | Keep disabled |

**Applying changes:**

The config file is in `C:\ProgramData\MySQL\MySQL Server 8.0\` which requires admin
to write. The tuned config lives at `D:\code\wow-server\my.ini`. To deploy:

```powershell
# As Administrator, with MySQL stopped:
Copy-Item -Force "D:\code\wow-server\my.ini" "C:\ProgramData\MySQL\MySQL Server 8.0\my.ini"
Start-Service MySQL80
```

Most InnoDB settings can also be applied dynamically without restart:

```sql
SET GLOBAL innodb_flush_log_at_trx_commit = 0;
SET GLOBAL innodb_buffer_pool_size = 2147483648;
SET GLOBAL innodb_io_capacity = 2000;
SET GLOBAL innodb_io_capacity_max = 4000;
SET GLOBAL innodb_max_dirty_pages_pct = 90;
SET GLOBAL innodb_max_dirty_pages_pct_lwm = 10;
SET GLOBAL innodb_change_buffering = 'all';
SET GLOBAL max_connections = 500;
SET GLOBAL table_open_cache = 8000;
```

**Verification:**

```sql
SHOW ENGINE INNODB STATUS\G
-- Look for: "Buffer pool hit rate 1000 / 1000" = all reads from RAM
-- Look for: "0.00 reads/s" = zero disk reads
```

**Note:** Even with full InnoDB tuning, there will still be some write I/O to the MySQL
data directory because InnoDB must persist redo logs and dirty pages to disk for crash
recovery. To eliminate even this residual I/O, use the RAM disk setup in section 15d.

### 15d. MySQL RAM Disk (Zero Disk I/O)

The ultimate optimization: run the entire MySQL database from RAM, syncing back to
SSD every 15 minutes. This eliminates **all** C: drive I/O during gameplay.

**Why VHD-on-RAM?** MySQL 8.0 requires NTFS volume APIs (`GetVolumePathName`,
`GetFileInformationByHandle`) that ImDisk's direct volume driver doesn't implement
(OS error 1: `ERROR_INVALID_FUNCTION`). The workaround is a **VHD disk image**
stored on the ImDisk RAM drive — the VHD provides a fully compliant NTFS volume
while the underlying file lives entirely in RAM.

**Requirements:**
- 64 GB system RAM (47+ GB free)
- ~2.8 GB database + growth headroom → 4 GB RAM disk (3 GB VHD inside it)
- ImDisk Toolkit (free, open-source RAM disk driver for Windows)

**Architecture:**

```
BOOT:
  Task Scheduler → 3-start-ramdisk.ps1
  1. imdisk creates 4 GB RAM disk on R:
  2. diskpart creates VHD file on R:\, mounts as S:\
  3. robocopy D:\...\mysql-data-backup → S:\ (restore)
  4. Start MySQL80 → datadir=S:\ (VHD on RAM)

RUNTIME (every 15 min):
  Task Scheduler → sync-to-disk.ps1
  robocopy S:\ → D:\...\mysql-data-backup (incremental, newer files only)

SHUTDOWN:
  Run manually: shutdown-sync.ps1
  1. Stop MySQL80
  2. Final full sync S:\ → D:\...\mysql-data-backup
  3. diskpart detaches VHD from S:\
  4. imdisk dismounts R:\ RAM disk
```

**Drive layout when running:**

| Drive | Type | Contents |
|-------|------|----------|
| `R:` | ImDisk RAM disk (NTFS) | `mysql-data.vhd` (3 GB VHD file) |
| `S:` | VHD mounted from `R:\mysql-data.vhd` (NTFS) | MySQL data directory (`datadir=S:\`) |

**Scripts** (all in `D:\code\wow-server\ramdisk\`):

| Script | Purpose | Run |
|--------|---------|-----|
| `1-install-driver.ps1` | Install ImDisk driver | Once, as Admin |
| `2-prepare-backup.ps1` | Backup MySQL data, update config to `datadir=S:\`, set MySQL to Manual start | Once, as Admin |
| `3-start-ramdisk.ps1` | Create RAM disk → create VHD → restore data → start MySQL | Every boot (automated) |
| `4-setup-tasks.ps1` | Register Task Scheduler jobs for boot + 15-min sync | Once, as Admin |
| `sync-to-disk.ps1` | Incremental sync S:\ (VHD) → SSD | Every 15 min (automated) |
| `shutdown-sync.ps1` | Stop MySQL → final sync → detach VHD → dismount RAM | Manually before shutdown/restart |

**Setup procedure (run in order as Administrator):**

```powershell
# Step 1: Install RAM disk driver
PowerShell -ExecutionPolicy Bypass -File "D:\code\wow-server\ramdisk\1-install-driver.ps1"

# Step 2: Backup MySQL data + point config at S:\
PowerShell -ExecutionPolicy Bypass -File "D:\code\wow-server\ramdisk\2-prepare-backup.ps1"

# Step 3: Start MySQL on RAM disk (test it works)
PowerShell -ExecutionPolicy Bypass -File "D:\code\wow-server\ramdisk\3-start-ramdisk.ps1"

# Step 4: Register automated tasks
PowerShell -ExecutionPolicy Bypass -File "D:\code\wow-server\ramdisk\4-setup-tasks.ps1"
```

**Verification:**

```sql
SHOW VARIABLES LIKE 'datadir';   -- Should show S:\
SHOW ENGINE INNODB STATUS\G      -- Buffer pool hit rate should reach 1000/1000
```

The buffer pool hit rate starts around 67-96% after a fresh start and climbs to
100% as InnoDB caches all data in the 2 GB buffer pool.

**Daily workflow (see Section 9 for full details):**

| When | Action |
|---|---|
| **Boot** | Task Scheduler auto-runs `3-start-ramdisk.ps1` → RAM disk + VHD + MySQL ready |
| **Play** | Start `realmd.exe` → start `mangosd.exe` (section 9c) |
| **Every 15 min** | Task Scheduler auto-runs `sync-to-disk.ps1` (incremental backup) |
| **Shutdown** | Ctrl+C mangosd → Ctrl+C realmd → **run `shutdown-sync.ps1` as Admin** (section 9d) |

**⚠️ Critical:** Always run `shutdown-sync.ps1` before restarting or shutting down.
Otherwise, all database changes since the last 15-minute sync are lost.

**Reverting to disk-based MySQL:**

```powershell
# As Administrator:
Stop-Service MySQL80
# Detach VHD and dismount RAM disk
imdisk -d -m R: 2>$null
# Restore original config
Copy-Item "C:\ProgramData\MySQL\MySQL Server 8.0\my.ini.backup" "C:\ProgramData\MySQL\MySQL Server 8.0\my.ini" -Force
Set-Service MySQL80 -StartupType Automatic
Start-Service MySQL80
```

**Directory summary after RAM disk setup:**

```
D:\code\wow-server\
├── mysql-data-backup\       # SSD backup of MySQL data (synced every 15 min)
├── ramdisk\                 # RAM disk management scripts
│   ├── 1-install-driver.ps1
│   ├── 2-prepare-backup.ps1
│   ├── 3-start-ramdisk.ps1
│   ├── 4-setup-tasks.ps1
│   ├── sync-to-disk.ps1
│   └── shutdown-sync.ps1
├── my.ini                   # Tuned MySQL config (datadir=S:\)
└── ...
```
