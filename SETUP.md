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
9. [Start the Server](#9-start-the-server)
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
git clone https://github.com/cmangos/playerbots.git D:\code\wow-server\mangos-classic\src\modules\PlayerBots --depth 1
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

## 9. Start the Server

**Both servers must run simultaneously** — use two separate PowerShell/terminal windows.

### Terminal 1 — Auth Server (realmd):
```powershell
cd D:\code\wow-server\mangos-install
.\realmd.exe
```
Expected: `[CMaNGOS Classic Login server v0.18]` — keeps running quietly.

### Terminal 2 — World Server (mangosd):
```powershell
cd D:\code\wow-server\mangos-install
.\mangosd.exe
```
Expected: loads for 30-60 seconds then shows `mangos>` prompt.

**Healthy server indicators:**
- `Avg Diff: ~50-80` — tick loop at target speed
- `Max Diff: < 500` — no major lag spikes
- `Sessions online: 0` (until you log in, then shows your session + bots)
- No `Critical Error` or `MANGOS_ASSERT` messages

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

Full bot command reference: https://github.com/cmangos/playerbots

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
| `dbc\` | `mangos-install\` | Extracted DBC data files |
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
│   ├── vmaps\              # (optional)
│   ├── mmaps\              # (optional)
│   └── tools\
│       ├── ad.exe
│       ├── vmap_extractor.exe
│       ├── vmap_assembler.exe
│       └── MoveMapGen.exe
└── SETUP.md                # This guide

C:\local\boost_1_86_0\      # Boost libraries

C:\World of Warcraft Classic\  # WoW client
```
