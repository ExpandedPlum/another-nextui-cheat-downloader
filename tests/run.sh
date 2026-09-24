#!/bin/sh
# shellcheck shell=dash disable=SC2016 # jq programs are single-quoted
# Offline tests for Another Cheat Downloader. minui-list, minui-presenter and
# curl are replaced by the stubs in tests/stubs.
#
#   sh tests/run.sh                      host tools
#   BUSYBOX=1 busybox sh tests/run.sh    BusyBox tools and shell, as on the device
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
PASSES=0
FAILURES=0

if [ -n "${BUSYBOX:-}" ]; then
  BB_BIN=$(mktemp -d)
  for applet in awk basename cat cp date dirname find grep head kill ls mkdir sh \
      mktemp mv printf rm sed sleep sort touch tr wc; do
    ln -s "$(command -v busybox)" "$BB_BIN/$applet"
  done
  PATH="$BB_BIN:$PATH"
fi
PATH="$REPO/tests/stubs:$PATH"
export PATH

# ── Assertions ────────────────────────────────────────────────────────────────

fail() {
  echo "    FAIL: $*"
  TEST_FAILED=1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "${3:-values differ}: expected [$2], got [$1]"
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_no_file() {
  [ ! -e "$1" ] || fail "unexpected file: $1"
}

assert_log() {
  grep -qF -- "$1" "$STUB_LOG" || fail "log has no line containing [$1]"
}

assert_no_log() {
  ! grep -qF -- "$1" "$STUB_LOG" || fail "log unexpectedly contains [$1]"
}

# jq with the pak's module loaded: q FILTER [jq args...]
q() {
  local filter="$1"
  shift
  jq -L "$REPO/lib" "include \"cheats\"; $filter" "$@"
}

# ── Fixtures ──────────────────────────────────────────────────────────────────

setup() {
  T=$(mktemp -d)
  export PAK_DIR="$REPO" PAK_NAME="Another Cheat Downloader" PLATFORM=test
  export SDCARD_PATH="$T/sd"
  export USERDATA_PATH="$SDCARD_PATH/.userdata/test"
  export LOGS_PATH="$USERDATA_PATH/logs"
  export CHEAT_INDEX_URL="https://stub.test/index"
  export LIBRETRO_RAW="https://stub.test/raw"
  export BUNDLED_INDEX_DIR="$T/bundled"
  export CA_BUNDLE="$T/cacert.pem"
  export STUB_WEB="$T/web" STUB_LOG="$T/stub.log" STUB_DIR="$T" STUB_LIST_SCRIPT="$T/list_script"
  unset STUB_CURL_MODE STUB_CONFIRM ROM_ROOT CHEATS_ROOT CACHE_DIR
  mkdir -p "$STUB_WEB" "$BUNDLED_INDEX_DIR" "$SDCARD_PATH/Roms"
  : > "$STUB_LOG"
  : > "$STUB_LIST_SCRIPT"
  # shellcheck source=lib/common.sh
  . "$REPO/lib/common.sh"
  init_config
}

uri() {
  printf '%s' "$1" | jq -Rr @uri
}

# index_json SYSTEM COMMIT GENERATED FILE...
index_json() {
  local system="$1" commit="$2" generated="$3"
  shift 3
  jq -n -c --arg s "$system" --arg c "$commit" --arg g "$generated" \
    '{format: 1, commit: $c, generated: $g, system: $s, files: $ARGS.positional}' --args "$@"
}

# publish_index SYSTEM COMMIT FILE...: make an index downloadable
publish_index() {
  local system="$1" commit="$2"
  shift 2
  mkdir -p "$STUB_WEB/index"
  index_json "$system" "$commit" "2026-09-02T00:00:00Z" "$@" > "$STUB_WEB/index/$(uri "$system").json"
}

# serve_cheat SYSTEM COMMIT FILE [CONTENT]: make a cheat file downloadable
serve_cheat() {
  local dir
  dir="$STUB_WEB/raw/$2/cht/$(uri "$1")"
  mkdir -p "$dir"
  printf '%s\n' "${4:-cheats = 1}" > "$dir/$(uri "$3")"
}

list_script() {
  printf '%s\n' "$@" > "$STUB_LIST_SCRIPT"
  rm -f "$STUB_LIST_SCRIPT.pos"
}

SNES="Nintendo - Super Nintendo Entertainment System"
SMW_FILES="Super Mario World (USA) (Game Genie).cht
Super Mario World (World) (Action Replay).cht
Super Mario World (Japan).cht
Super Mario Kart (USA).cht
Chrono Trigger (USA).cht
Chrono Trigger (USA) (Game Genie).cht"

# ── Name parsing and matching (lib/cheats.jq) ─────────────────────────────────

test_display_names() {
  display() { jq -rn -L "$REPO/lib" --arg n "$1" 'include "cheats"; $n | name_meta | display_name'; }
  assert_eq "$(display "Pokemon - Crystal Version (USA, Europe) (Rev 1) (GameShark)")" \
    "[GS|US,EU] Pokemon - Crystal Version (Rev 1)"
  assert_eq "$(display "Pokemon - Ruby Version (Code Breaker)(USA)")" "[CB|US] Pokemon - Ruby Version"
  assert_eq "$(display "Tetris (Korea)")" "[KR] Tetris"
  assert_eq "$(display "Tetris (France, Germany, Spain)")" "[FR,DE,ES] Tetris"
  assert_eq "$(display "Resident Evil 2 (USA) (Game Buster)")" "[GBu|US] Resident Evil 2"
  assert_eq "$(display "Mario Kart DS (USA) (Mario Kart Zero (v1.3))")" "[US] Mario Kart DS (Mario Kart Zero (v1.3))"
  assert_eq "$(display "(Unnamed)")" "(Unnamed)"
}

test_match_keys() {
  key() { jq -rn -L "$REPO/lib" --arg n "$1" 'include "cheats"; $n | rom_meta | .key'; }
  assert_eq "$(key "The Legend of Zelda - A Link to the Past (USA).sfc")" \
    "$(key "Legend of Zelda, The - A Link to the Past (USA).sfc")" "leading article"
  assert_eq "$(key "Pokémon - Emerald Version (USA, Europe).gba")" "pokemonemeraldversion" "accents"
  assert_eq "$(key "Sonic & Knuckles (World).md")" "sonicandknuckles" "ampersand"
  assert_eq "$(jq -cn -L "$REPO/lib" 'include "cheats"; "Zelda (U) [!].smc" | rom_meta | .regions')" '["US"]' "GoodTools region"
}

test_cheat_list_unique_names() {
  local names
  names=$(index_json "X" c1 g "4 Elements (Europe) (Fr,De).cht" "4 Elements (Europe) (Fr,Nl).cht" \
      "4 Elements (Europe).cht" "NCAA Football (U).cht" "NCAA Football (USA).cht" "notes.txt" \
    | q 'cheat_list | .items[].name' -r)
  assert_eq "$(printf '%s\n' "$names" | wc -l | tr -d ' ')" "5" "non-.cht files dropped"
  assert_eq "$(printf '%s\n' "$names" | sort -u | wc -l | tr -d ' ')" "5" "names unique"
  printf '%s\n' "$names" | grep -qxF "[EU] 4 Elements (Fr,De)" || fail "language tag used to disambiguate: $names"
  printf '%s\n' "$names" | grep -qxF "[EU] 4 Elements" || fail "unambiguous name kept short"
}

test_ranking() {
  local list="$T/list.json" ranked
  printf '%s\n' "$SMW_FILES" | jq -R -s -c '{format: 1, commit: "c1", system: "S", files: split("\n") | map(select(. != ""))}' \
    | q 'cheat_list' > "$list"
  ranked=$(q 'ranked_for_rom("Super Mario World (USA).sfc") | .items[] | if .is_header then "# \(.name)" else .name end' -r "$list")
  assert_eq "$(printf '%s\n' "$ranked" | head -5 | tr '\n' '|')" \
    "# Best matches|[GG|US] Super Mario World|# Same game|[AR|WD] Super Mario World|# Same game, other regions|"
  assert_eq "$(q 'ranked_for_rom("Super Mario World (USA).sfc") | .matched' "$list")" "3"
  assert_eq "$(q 'ranked_for_rom("Zzz.sfc") | .matched' "$list")" "0" "no matches"
}

test_bulk_plan() {
  local list="$T/list.json" roms="$T/roms.json"
  printf '%s\n' "$SMW_FILES" | jq -R -s -c '{format: 1, commit: "c1", system: "S", files: split("\n") | map(select(. != ""))}' \
    | q 'cheat_list' > "$list"
  jq -n '{items: [
    {game: "Super Mario World (USA).sfc", has_cheat: false},
    {game: "Chrono Trigger (USA).sfc", has_cheat: false},
    {game: "Super Mario Kart (Europe).sfc", has_cheat: false},
    {game: "Zzz (USA).sfc", has_cheat: false},
    {game: "Super Mario Kart (USA).sfc", has_cheat: true}
  ]}' > "$roms"
  assert_eq "$(q 'bulk_plan($c[0])' -c --slurpfile c "$list" "$roms")" \
    '{"auto":[{"rom":0,"file":"Super Mario World (USA) (Game Genie).cht"}],"review":[1,2],"none":1,"existing":1}'
}

# ── ROM library ───────────────────────────────────────────────────────────────

test_available_systems() {
  local r="$ROM_ROOT"
  mkdir -p "$r/Game Boy Advance (MGBA)" "$r/01) Super Nintendo (SFC)" "$r/Unknown (XYZ)" \
    "$r/Empty (GB)" "$r/PlayStation (PS)/FF7 (USA)" "$r/Hidden (GBC)/.media" "$r/No Code"
  touch "$r/Game Boy Advance (MGBA)/a.gba" "$r/01) Super Nintendo (SFC)/b.SFC" "$r/Unknown (XYZ)/c.gba" \
    "$r/Empty (GB)/readme.txt" "$r/PlayStation (PS)/FF7 (USA)/FF7 (USA).m3u" \
    "$r/Hidden (GBC)/.media/x.gbc" "$r/No Code/d.gba"
  build_available_systems "$T/systems.json"
  assert_eq "$(jq -r '.items[] | "\(.name)=\(.short)=\(.system)"' "$T/systems.json" | tr '\n' '|')" \
    "Super Nintendo (SFC)=SFC=$SNES|Game Boy Advance (MGBA)=MGBA=Nintendo - Game Boy Advance|PlayStation (PS)=PS=Sony - PlayStation|"
}

test_roms_list() {
  local d="$ROM_ROOT/PlayStation (PS)" out="$T/roms.json"
  mkdir -p "$d/FF7 (USA)" "$d/Spyro (USA)" "$d/Hacks" "$d/Discs" "$d/.media" "$CHEATS_ROOT/PS"
  printf '%s\n' "FF7 (USA) (Disc 1).chd" "FF7 (USA) (Disc 2).chd" > "$d/FF7 (USA)/FF7 (USA).m3u"
  touch "$d/FF7 (USA)/FF7 (USA) (Disc 1).chd" "$d/FF7 (USA)/FF7 (USA) (Disc 2).chd"
  printf 'FILE "Crash (USA) (Track 1).bin" BINARY\r\n  TRACK 01 MODE2/2352\r\nFILE "Crash (USA) (Track 2).bin" BINARY\r\n' \
    > "$d/Crash (USA).cue"
  touch "$d/Crash (USA) (Track 1).bin" "$d/Crash (USA) (Track 2).bin" "$d/.media/Crash (USA).png"
  printf 'FILE "Spyro (USA).bin" BINARY\n' > "$d/Spyro (USA)/Spyro (USA).cue"
  touch "$d/Spyro (USA)/Spyro (USA).bin" "$d/Hacks/Tony Hawk.bin"
  printf '# discs\n./Discs/Multi (Disc 1).chd\n' > "$d/Multi.m3u"
  touch "$d/Discs/Multi (Disc 1).chd"
  touch "$CHEATS_ROOT/PS/Crash (USA).cue.cht" "$CHEATS_ROOT/PS/Tony Hawk.cht"

  build_roms_list "$d" PS "$out"
  assert_eq "$(jq -r '.items[] | "\(.name)=\(.game)=\(.has_cheat)"' "$out" | tr '\n' '|')" \
    "Crash (USA).cue=Crash (USA).cue=true|FF7 (USA)=FF7 (USA).m3u=false|Hacks/Tony Hawk.bin=Tony Hawk.bin=true|Multi.m3u=Multi.m3u=false|Spyro (USA)=Spyro (USA).cue=false|"
  assert_eq "$(jq -r '.items[1].file' "$out")" "$d/FF7 (USA)/FF7 (USA).m3u"
}

# ── Cache and network ─────────────────────────────────────────────────────────

test_cache_expired() {
  local f="$T/cache.json"
  cache_expired "$f" || fail "missing file should be expired"
  touch "$f"
  cache_expired "$f" && fail "new file should not be expired"
  touch -t 202001010000 "$f"
  cache_expired "$f" || fail "old file should be expired"
}

test_fetch_tls_fallback() {
  mkdir -p "$STUB_WEB/files"
  echo hello > "$STUB_WEB/files/a"
  echo pem > "$CA_BUNDLE"
  STUB_CURL_MODE=notls
  export STUB_CURL_MODE
  fetch "https://stub.test/files/a" "$T/a" || fail "fetch should fall back to no verification"
  assert_eq "$(cat "$T/a")" "hello"
  assert_eq "$CURL_INSECURE" "1"
  : > "$STUB_LOG"
  fetch "https://stub.test/files/a" "$T/b" || fail "second fetch"
  assert_eq "$(wc -l < "$STUB_LOG" | tr -d ' ')" "1" "no second verification attempt"
}

test_fetch_failure_leaves_nothing() {
  STUB_CURL_MODE=offline
  export STUB_CURL_MODE
  fetch "https://stub.test/files/a" "$T/a" && fail "fetch should fail offline"
  assert_no_file "$T/a"
  assert_no_file "$T/a.part"
}

test_load_online() {
  publish_index "$SNES" c1 "Super Mario World (USA) (Game Genie).cht" "Chrono Trigger (USA).cht"
  load_cheat_list "$SNES" || fail "load"
  assert_eq "$(jq -r '.commit' "$CHEAT_LIST")" "c1"
  assert_eq "$(list_count "$CHEAT_LIST")" "2"
  : > "$STUB_LOG"
  load_cheat_list "$SNES" || fail "cached load"
  assert_no_log "curl:"
}

test_load_refreshes_expired_cache() {
  publish_index "$SNES" c1 "Chrono Trigger (USA).cht"
  load_cheat_list "$SNES"
  publish_index "$SNES" c2 "Chrono Trigger (USA).cht" "Super Mario World (USA).cht"
  touch -t 202001010000 "$CACHE_DIR/index/$(system_slug "$SNES").json"
  load_cheat_list "$SNES"
  assert_eq "$(jq -r '.commit' "$CHEAT_LIST")" "c2" "processed list rebuilt for new index"
  assert_eq "$(list_count "$CHEAT_LIST")" "2"
}

test_load_offline_uses_bundled() {
  index_json "$SNES" bundled1 "2026-09-01T00:00:00Z" "Chrono Trigger (USA).cht" > "$BUNDLED_INDEX_DIR/$SNES.json"
  STUB_CURL_MODE=offline
  export STUB_CURL_MODE
  load_cheat_list "$SNES" || fail "load"
  assert_eq "$(jq -r '.commit' "$CHEAT_LIST")" "bundled1"
}

test_load_offline_prefers_newer_stale_cache() {
  local idx
  idx="$CACHE_DIR/index/$(system_slug "$SNES").json"
  index_json "$SNES" bundled1 "2026-09-01T00:00:00Z" "Chrono Trigger (USA).cht" > "$BUNDLED_INDEX_DIR/$SNES.json"
  index_json "$SNES" cached2 "2026-09-20T00:00:00Z" "Chrono Trigger (USA).cht" > "$idx"
  touch -t 202001010000 "$idx"
  STUB_CURL_MODE=offline
  export STUB_CURL_MODE
  load_cheat_list "$SNES" || fail "load"
  assert_eq "$(jq -r '.commit' "$CHEAT_LIST")" "cached2"
}

test_load_nothing_available() {
  STUB_CURL_MODE=offline
  export STUB_CURL_MODE
  load_cheat_list "$SNES" && fail "load should fail"
  assert_log "Couldn't load cheats"
}

# ── Picking and saving cheats ─────────────────────────────────────────────────

test_pick_saves_under_nextui_name() {
  publish_index "$SNES" c1 "Super Mario World (USA) (Game Genie).cht" "Chrono Trigger (USA).cht"
  serve_cheat "$SNES" c1 "Super Mario World (USA) (Game Genie).cht" "cheats = 7"
  load_cheat_list "$SNES"
  list_script "0 1"   # item 0 is the "Best matches" header
  pick_cheat_for_rom SFC "Super Mario World (USA).sfc" "Super Mario World (USA).sfc" || fail "pick"
  assert_eq "$(cat "$CHEATS_ROOT/SFC/Super Mario World (USA).sfc.cht")" "cheats = 7"
}

test_pick_keeps_existing_when_declined() {
  publish_index "$SNES" c1 "Chrono Trigger (USA).cht"
  serve_cheat "$SNES" c1 "Chrono Trigger (USA).cht" "cheats = 2"
  load_cheat_list "$SNES"
  mkdir -p "$CHEATS_ROOT/SFC"
  echo "cheats = 1" > "$CHEATS_ROOT/SFC/Chrono Trigger (USA).sfc.cht"
  list_script "0 1"
  STUB_CONFIRM=2
  export STUB_CONFIRM
  pick_cheat_for_rom SFC "Chrono Trigger (USA).sfc" "x" && fail "pick should be cancelled"
  assert_eq "$(cat "$CHEATS_ROOT/SFC/Chrono Trigger (USA).sfc.cht")" "cheats = 1"
  assert_log "Replace the existing cheat file"
}

test_download_rejects_non_cheat() {
  publish_index "$SNES" c1 "Chrono Trigger (USA).cht"
  serve_cheat "$SNES" c1 "Chrono Trigger (USA).cht" "<html>rate limited</html>"
  load_cheat_list "$SNES"
  download_cheat "$CHEAT_LIST" "Chrono Trigger (USA).cht" SFC "Chrono Trigger (USA).sfc" && fail "should reject"
  assert_no_file "$CHEATS_ROOT/SFC/Chrono Trigger (USA).sfc.cht"
}

# ── Whole app ─────────────────────────────────────────────────────────────────

test_launch_get_all() {
  local d="$ROM_ROOT/Super Nintendo (SFC)" f old_ifs
  mkdir -p "$d"
  touch "$d/Super Mario World (USA).sfc" "$d/Chrono Trigger (USA).sfc" "$d/Unknown Game.sfc"
  old_ifs=$IFS
  IFS='
'
  # shellcheck disable=SC2086 # split on newlines only
  set -- $SMW_FILES
  IFS=$old_ifs
  publish_index "$SNES" c1 "$@"
  printf '%s\n' "$SMW_FILES" | while IFS= read -r f; do serve_cheat "$SNES" c1 "$f"; done

  # System list: pick SNES. ROM list: X (GET ALL). Review list: Back.
  # ROM list: Back. System list: Back.
  list_script "0 0" "4" "2" "2" "2"
  sh "$REPO/launch.sh" || fail "launch.sh exited non-zero"

  assert_file "$CHEATS_ROOT/SFC/Super Mario World (USA).sfc.cht"
  assert_no_file "$CHEATS_ROOT/SFC/Chrono Trigger (USA).sfc.cht"
  assert_log "Download cheats for 1 games?"
  assert_log "list: Pick cheats (1 left) (1 items)"
  assert_eq "$(jq -r '.items[0].game' "$T/list_3.json")" "Chrono Trigger (USA).sfc" "review list"
  # launch.sh names the log after the pak folder, i.e. this checkout
  assert_file "$LOGS_PATH/$(basename "$REPO").txt"
}

# ── Runner ────────────────────────────────────────────────────────────────────

# shellcheck disable=SC2013 # test names are single words
for t in $(grep -oE '^test_[a-z_]+' "$0"); do
  if (
    TEST_FAILED=0
    setup
    ROM_ROOT="$SDCARD_PATH/Roms"
    "$t"
    rm -rf "$T"
    [ "$TEST_FAILED" -eq 0 ]
  ); then
    PASSES=$((PASSES + 1))
    echo "ok   $t"
  else
    FAILURES=$((FAILURES + 1))
    echo "FAIL $t"
  fi
done

echo "$PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ]
