# Another Cheat Downloader

A NextUI/MinUI pak for downloading cheat files directly to your device from the [Libretro cheat database](https://github.com/libretro/libretro-database/tree/master/cht). No computer required — browse your ROM library, pick a cheat, and it downloads and saves automatically.

---

## Requirements

- **Device:** Trimui Brick or Trimui Smart Pro (platform: `tg5040`), or a NextUI `tg5050` device
- **Firmware:** NextUI or MinUI (`tg5050` is NextUI-only)
- **Network:** Wi-Fi is needed to download cheats. Cheat lists also work offline from a copy bundled with the pak.

---

## Installation

1. Mount your MinUI SD card.
2. Download the latest `Another Cheat Downloader.pak.zip` from [GitHub Releases](https://github.com/ExpandedPlum/another-nextui-cheat-downloader/releases).
3. Create the folder `/Tools/tg5040/Another Cheat Downloader.pak/` on your SD card (use `tg5050` instead of `tg5040` on a `tg5050` device).
4. Extract the contents of the zip into that folder.
5. Confirm `/Tools/tg5040/Another Cheat Downloader.pak/launch.sh` exists.
6. Unmount the SD card and insert it into your device.

---

## Usage

Navigate to **Tools → Another Cheat Downloader** and press **A**.

### Step 1 — Select a System

The pak scans your `/Roms` folder and shows only systems that:
- Have a recognized folder short-code (e.g. `MGBA`, `SFC`, `PS`)
- Contain at least one ROM file with a supported extension

Select a system and press **A**.

### Step 2 — Select a ROM

Your games for that system are listed, including games in subfolders. Multi-disc games (a folder `Game/` containing `Game.m3u` or `Game.cue`) appear once, and disc tracks referenced by a `.cue` or `.m3u` are hidden.

- Press **A** to pick a cheat for one game.
- Press **X** (**GET ALL**) to download cheats for every game that doesn't have one yet. A cheat is downloaded automatically only when there is a single confident match: the same title and region, or the same title and a compatible region. Games with several possible cheats (for example both an Action Replay and a Game Genie file) are then listed so you can pick for each one.

### Step 3 — Select a Cheat

The cheat list is sorted by how well each cheat matches your ROM's file name, under these headings:

| Heading | Meaning |
|---------|---------|
| Best matches | Same title, region and revision |
| Same game | Same title, compatible region (or no region given) |
| Same game, other regions | Same title, different region |
| Similar names | One title contains the other |
| All other cheats | Everything else for the system |

Title matching ignores case, punctuation, accents and a leading or trailing "The", so `The Legend of Zelda (USA).sfc` matches `Legend of Zelda, The (USA)`. If you're replacing a cheat file that already exists, you're asked first.

Cheat entries are displayed in the format:

```
[TOOL|REGION] Game Title (other tags)
```

Other tags such as `(Rev 1)` or `(Demo)` are kept so similar files can be told apart.

| Prefix example | Meaning |
|----------------|---------|
| `[CB\|US]` | Code Breaker, USA |
| `[AR\|US,EU]` | Action Replay, USA + Europe |
| `[GS\|JP]` | GameShark, Japan |
| `[PAR\|EU]` | Pro Action Replay, Europe |
| `[GG\|WD]` | Game Genie, World |

**Tool abbreviations:**

| Code | Full name |
|------|-----------|
| `CB` | Code Breaker |
| `AR` | Action Replay |
| `PAR` | Pro Action Replay |
| `GS` | GameShark |
| `GG` | Game Genie |
| `GBu` | Game Buster |
| `XP` | Xploder |

**Region abbreviations:**

| Code | Region |
|------|--------|
| `US` | USA |
| `EU` | Europe |
| `JP` | Japan |
| `WD` | World |
| `AU` | Australia |
| `KR` | Korea |
| `BR` | Brazil |
| `DE` | Germany |
| `FR` | France |
| `ES` | Spain |
| `IT` | Italy |
| `AU` | Australia |
| `AS` | Asia |
| `??` | Unknown |

Less common regions use their two-letter country codes (`NL`, `CN`, `TW`, `HK`, `RU`, `CA`, `SE`).

Select the appropriate cheat and press **A**. The file downloads and saves automatically.

---

## Supported Systems

The following ROM folder short-codes are recognized:

| Folder code(s) | System |
|----------------|--------|
| `GBA`, `MGBA` | Game Boy Advance |
| `GBC` | Game Boy Color |
| `GB`, `GB0`, `SGB` | Game Boy |
| `FC`, `NES` | Nintendo Entertainment System |
| `SFC`, `SNES` | Super Nintendo Entertainment System |
| `N64` | Nintendo 64 |
| `NDS`, `NDS2` | Nintendo DS |
| `FDS` | Famicom Disk System |
| `MD`, `GEN`, `GENESIS` | Sega Mega Drive / Genesis |
| `GG` | Sega Game Gear |
| `SMS`, `SMSGG` | Sega Master System |
| `32X` | Sega 32X |
| `SS`, `SAT` | Sega Saturn |
| `DC` | Sega Dreamcast |
| `MCD`, `SCD` | Sega CD |
| `PS`, `PSX`, `PS1` | PlayStation |
| `PSP` | PlayStation Portable |
| `PCE`, `TG16` | PC Engine / TurboGrafx-16 |
| `PCECD` | PC Engine CD |
| `SGFX` | PC Engine SuperGrafx |
| `ATARI`, `A26` | Atari 2600 |
| `LYNX` | Atari Lynx |
| `A7800` | Atari 7800 |
| `ARCADE`, `FBN` | FBNeo Arcade |

Your ROM folders must follow the NextUI/MinUI naming convention: `System Name (CODE)` — for example, `Game Boy Advance (MGBA)` or `PlayStation (PS)`.

---

## Where Cheats Are Saved

Downloaded cheat files are saved to:

```
/mnt/SDCARD/Cheats/<SYSTEM_CODE>/<ROM_FILE_NAME>.cht
```

For example, a cheat for `Castlevania - Aria of Sorrow.gba` on the MGBA system saves to:

```
/mnt/SDCARD/Cheats/MGBA/Castlevania - Aria of Sorrow.gba.cht
```

This is the first name NextUI looks for, so the cheat loads automatically. For a multi-disc game in a folder, the name is the folder's `.m3u` (or `.cue`) file, e.g. `Final Fantasy VII (USA).m3u.cht`.

Versions before v0.2.0 saved cheats without the ROM extension (`Castlevania - Aria of Sorrow.cht`). NextUI still finds those, and **GET ALL** treats those games as already having a cheat.

---

## Cheat Lists and Caching

The list of cheat files for each system comes from an index that a GitHub Action in this repository rebuilds daily from the [Libretro cheat database](https://github.com/libretro/libretro-database/tree/master/cht) and publishes to the `cheat-index` branch. The pak downloads it from `raw.githubusercontent.com`, so it doesn't use GitHub's API: there is no hourly rate limit and no 1,000-file cap on big systems like SNES, DS or PlayStation.

Each system's index is cached for **24 hours**. If it can't be refreshed (for example, with Wi-Fi off), the pak uses the newer of the cached copy and the snapshot bundled with the release, so you can browse cheat lists offline. Cheat files themselves are always downloaded from the exact database version the index was built from.

To force a refresh before the 24-hour window, delete `/mnt/SDCARD/.userdata/<platform>/Another Cheat Downloader/index/` and relaunch the pak.

---

## Troubleshooting

**No systems appear in the list**
- Make sure your ROM folders use the `System Name (CODE)` naming convention
- Ensure ROM files have a supported extension (`.gba`, `.sfc`, `.iso`, etc.)

**"Couldn't load cheats" or "Download failed"**
- Verify Wi-Fi is connected on the device
- Downloads time out after about a minute, so a dropped connection won't leave the pak stuck

**"No close matches" shown for my ROM**
- No cheat file has the same or a similar title. The full cheat list for the system is shown so you can pick manually
- The log at `/mnt/SDCARD/.userdata/<platform>/logs/Another Cheat Downloader.txt` shows what happened

**A system I own is missing from the list**
- Its folder short-code may not be in the supported list above. Check the folder name on your SD card and open an issue if the code should be added

---

## Development

- `make test` runs the offline test suite twice: with the host's tools, and with BusyBox as on the device. `minui-list`, `minui-presenter` and `curl` are replaced by stubs in `tests/stubs`.
- `make lint` runs ShellCheck.
- `make index` builds the cheat index into `index/`, and `make certs` downloads the CA certificates the pak uses to verify HTTPS. `make release` runs both and includes them in the zip.
- `lib/cheats.jq` holds all name parsing and matching. `lib/common.sh` holds the device logic, and `launch.sh` just sets up and calls `main`.
- The `cheat-index` workflow runs daily; run it manually once after forking so the `cheat-index` branch exists. Until then, the pak uses the index bundled in the release.

---

## Acknowledgements

- Original author: [Mike Cosentino](https://github.com/mikecosentino)
- [minui-list](https://github.com/josegonzalez/minui-list) by Jose Diaz-Gonzalez
- [minui-presenter](https://github.com/josegonzalez/minui-presenter) by Jose Diaz-Gonzalez
- Cheat data sourced from the [Libretro cheat database](https://github.com/libretro/libretro-database/tree/master/cht)
