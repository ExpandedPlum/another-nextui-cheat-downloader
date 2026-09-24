# shellcheck shell=dash
# Another Cheat Downloader: functions shared by launch.sh and the tests.
# Sourcing this file has no side effects; call init_config before anything else.

# Format of the per-system cheat index files (see scripts/build-index.sh).
INDEX_FORMAT=1
CACHE_TTL_HOURS=24

# ROM extensions to include (pipe-separated for grep -E / jq test)
ROM_EXTENSIONS="gba|gbc|gb|nes|sfc|smc|n64|z64|v64|nds|fds|md|gen|smd|bin|gg|sms|32x|cue|iso|pbp|chd|cdi|gdi|cso|pce|sgx|psp|lnx|a78|a26|zip|7z|m3u"

TAB=$(printf '\t')

# Paths default to NextUI's environment, so tests and other platforms can
# override any of them.
init_config() {
  : "${PAK_DIR:?PAK_DIR must be set}"
  PAK_NAME="${PAK_NAME:-$(basename "$PAK_DIR" .pak)}"
  PLATFORM="${PLATFORM:-tg5040}"
  SDCARD_PATH="${SDCARD_PATH:-/mnt/SDCARD}"
  USERDATA_PATH="${USERDATA_PATH:-$SDCARD_PATH/.userdata/$PLATFORM}"
  LOGS_PATH="${LOGS_PATH:-$USERDATA_PATH/logs}"
  ROM_ROOT="${ROM_ROOT:-$SDCARD_PATH/Roms}"
  CHEATS_ROOT="${CHEATS_ROOT:-$SDCARD_PATH/Cheats}"
  CACHE_DIR="${CACHE_DIR:-$USERDATA_PATH/$PAK_NAME}"
  BUNDLED_INDEX_DIR="${BUNDLED_INDEX_DIR:-$PAK_DIR/index}"
  CA_BUNDLE="${CA_BUNDLE:-$PAK_DIR/certs/cacert.pem}"
  JQ_LIB="$PAK_DIR/lib"
  LIBRETRO_RAW="${LIBRETRO_RAW:-https://raw.githubusercontent.com/libretro/libretro-database}"

  # The index is published to the cheat-index branch of this pak's own repo
  # by .github/workflows/index.yml.
  if [ -z "${CHEAT_INDEX_URL:-}" ]; then
    local repo_url
    repo_url=$(jq -r '.repo_url // empty' "$PAK_DIR/pak.json" 2>/dev/null)
    CHEAT_INDEX_URL="https://raw.githubusercontent.com/${repo_url#https://github.com/}/cheat-index/v$INDEX_FORMAT"
  fi

  CURL_INSECURE=""
  STATUS_PID=""
  mkdir -p "$CACHE_DIR/index" "$CACHE_DIR/lists"
  # Files left by v0.1.x, which read the GitHub API directly
  rm -f "$CACHE_DIR"/cheats_*.json "$CACHE_DIR"/roms_*.json "$CACHE_DIR/cheats_raw.json" \
    "$CACHE_DIR/matched_cheats.json" "$CACHE_DIR/selected.cht"
}

# ── UI helpers ────────────────────────────────────────────────────────────────

show_status() {
  hide_status
  minui-presenter --message "$1" --timeout -1 &
  STATUS_PID=$!
}

hide_status() {
  if [ -n "$STATUS_PID" ]; then
    kill "$STATUS_PID" 2>/dev/null
    wait "$STATUS_PID" 2>/dev/null
    STATUS_PID=""
  fi
}

show_message() {
  hide_status
  minui-presenter --message "$1" --timeout "${2:-3}"
}

# Message that stays up until the user presses A
show_notice() {
  hide_status
  minui-presenter --message "$1" --confirm-show --confirm-text "OK" --timeout 0
}

# Returns 0 if the user confirms
confirm() {
  hide_status
  minui-presenter --message "$1" --confirm-show --confirm-text "$2" \
    --cancel-show --cancel-text "$3" --timeout 0
}

# display_list JSON TITLE STATE_FILE [extra minui-list args...]
# Returns minui-list's exit code: 0 selected, 2/3 back, 4 action button.
display_list() {
  local json_file="$1" title="$2" state_file="$3" r
  shift 3
  rm -f "$state_file"
  minui-list --file "$json_file" --item-key "items" --title "$title" \
    --write-value state --write-location "$state_file" "$@"
  r=$?
  [ $r -ne 0 ] && echo "minui-list exited $r at: $title"
  return $r
}

# Prints the selected index from a minui-list state file, or fails.
selected_index() {
  local sel
  sel=$(jq -r '.selected // empty' "$1" 2>/dev/null)
  case "$sel" in
    '' | *[!0-9]*) return 1 ;;
  esac
  echo "$sel"
}

list_count() {
  jq '[.items[] | select(.is_header != true)] | length' "$1" 2>/dev/null || echo 0
}

# ── Network ───────────────────────────────────────────────────────────────────

_curl() {
  local mode="$1" url="$2" out="$3" max_time="$4"
  if [ "$mode" = insecure ]; then
    curl -fsSL -k --connect-timeout 10 --max-time "$max_time" -o "$out" "$url"
  elif [ -f "$CA_BUNDLE" ]; then
    curl -fsSL --cacert "$CA_BUNDLE" --connect-timeout 10 --max-time "$max_time" -o "$out" "$url"
  else
    curl -fsSL --connect-timeout 10 --max-time "$max_time" -o "$out" "$url"
  fi
}

# fetch URL DEST [MAX_SECONDS]
# Downloads to DEST only on success. TLS is verified against the CA bundle
# shipped in the pak. If this device's curl can't verify certificates at all
# (exit 60/77), it retries once without verification and stays that way for
# the session rather than leaving the pak unusable.
fetch() {
  local url="$1" dest="$2" max_time="${3:-60}" rc=0
  rm -f "$dest.part"
  _curl "${CURL_INSECURE:+insecure}" "$url" "$dest.part" "$max_time" || rc=$?
  if [ -z "$CURL_INSECURE" ] && { [ $rc -eq 60 ] || [ $rc -eq 77 ]; }; then
    echo "TLS verification unavailable (curl exit $rc); continuing without it"
    CURL_INSECURE=1
    rc=0
    _curl insecure "$url" "$dest.part" "$max_time" || rc=$?
  fi
  if [ $rc -ne 0 ]; then
    echo "Download failed (curl exit $rc): $url"
    rm -f "$dest.part"
    return 1
  fi
  mv "$dest.part" "$dest"
}

# ── Cache helpers ─────────────────────────────────────────────────────────────

# Returns 0 (true) if file doesn't exist or is older than CACHE_TTL_HOURS
cache_expired() {
  [ ! -f "$1" ] && return 0
  [ -n "$(find "$1" -mmin +$((CACHE_TTL_HOURS * 60)) 2>/dev/null)" ]
}

system_slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'
}

# ── System mappings ───────────────────────────────────────────────────────────

# Map MinUI ROM folder short code → Libretro system name
short_to_libretro() {
  case "$1" in
    GBA|MGBA)       echo "Nintendo - Game Boy Advance" ;;
    GBC)            echo "Nintendo - Game Boy Color" ;;
    GB|GB0|SGB)     echo "Nintendo - Game Boy" ;;
    FC|NES)         echo "Nintendo - Nintendo Entertainment System" ;;
    SFC|SNES)       echo "Nintendo - Super Nintendo Entertainment System" ;;
    N64)            echo "Nintendo - Nintendo 64" ;;
    NDS|NDS2)       echo "Nintendo - Nintendo DS" ;;
    FDS)            echo "Nintendo - Family Computer Disk System" ;;
    MD|GEN|GENESIS) echo "Sega - Mega Drive - Genesis" ;;
    GG)             echo "Sega - Game Gear" ;;
    SMS|SMSGG)      echo "Sega - Master System - Mark III" ;;
    32X)            echo "Sega - 32X" ;;
    SS|SAT)         echo "Sega - Saturn" ;;
    DC)             echo "Sega - Dreamcast" ;;
    MCD|SCD)        echo "Sega - Mega-CD - Sega CD" ;;
    PS|PSX|PS1)     echo "Sony - PlayStation" ;;
    PSP)            echo "Sony - PlayStation Portable" ;;
    PCE|TG16)       echo "NEC - PC Engine - TurboGrafx 16" ;;
    PCECD)          echo "NEC - PC Engine CD - TurboGrafx-CD" ;;
    SGFX)           echo "NEC - PC Engine SuperGrafx" ;;
    ATARI|A26)      echo "Atari - 2600" ;;
    LYNX)           echo "Atari - Lynx" ;;
    A7800)          echo "Atari - 7800" ;;
    ARCADE|FBN)     echo "FBNeo - Arcade Games" ;;
    *)              echo "" ;;
  esac
}

# ── ROM library ───────────────────────────────────────────────────────────────

# Lists files in a ROM folder, up to two subfolders deep, skipping hidden
# files and folders (.media, .res, ...)
find_rom_files() {
  find "$1" -maxdepth 3 -name '.*' -prune -o -type f -print
}

# Scan ROM_ROOT for folders that have ROMs AND a known Libretro mapping
build_available_systems() {
  local out="$1" tsv="$CACHE_DIR/systems.tsv" dir folder short system
  : > "$tsv"

  for dir in "$ROM_ROOT"/*/; do
    [ -d "$dir" ] || continue
    dir="${dir%/}"
    folder=$(basename "$dir")

    # Extract short code from folder name like "Game Boy Advance (GBA)"
    case "$folder" in
      *\(*\)*) short=$(printf '%s\n' "$folder" | sed -n 's/.*(\(.*\)).*/\1/p') ;;
      *) continue ;;
    esac
    [ -z "$short" ] && continue

    system=$(short_to_libretro "$short")
    [ -z "$system" ] && continue

    find_rom_files "$dir" | grep -qiE "\.(${ROM_EXTENSIONS})$" || continue

    printf '%s\t%s\t%s\t%s\n' "$folder" "$short" "$system" "$dir" >> "$tsv"
  done

  # Display the folder name as NextUI does, without any "01) " sort prefix
  jq -R -s '
    split("\n") | map(select(. != "") | split("\t")) |
    { items: map({ name: (.[0] | sub("^[0-9]+\\)\\s*"; "")),
                   short: .[1], system: .[2], rom_dir: .[3] }) }
  ' "$tsv" > "$out"
}

# Prints "<dir>/<file>" for every file referenced by a .cue or .m3u playlist
# in the given list of files (disc tracks, individual discs of a multi-disc
# game), so they are not offered as separate games.
playlist_refs() {
  local list is_cue
  grep -iE '\.(cue|m3u)$' "$1" | while IFS= read -r list; do
    case "$list" in
      *.[cC][uU][eE]) is_cue=1 ;;
      *) is_cue=0 ;;
    esac
    awk -v dir="${list%/*}" -v cue="$is_cue" '
      { sub(/\r$/, "") }
      cue && $1 == "FILE" {
        if (match($0, /"[^"]*"/)) print dir "/" substr($0, RSTART + 1, RLENGTH - 2)
        else print dir "/" $2
        next
      }
      !cue && $0 !~ /^[ \t]*(#|$)/ {
        line = $0
        sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
        print dir "/" line
      }
    ' "$list"
  done
}

# build_roms_list ROM_DIR TAG OUT
# Writes the games in a ROM folder as a minui-list JSON file. Each item has:
#   name      shown in the list (path relative to the ROM folder)
#   file      full path of the file NextUI launches
#   game      NextUI's name for the game, which cheat files are named after
#   has_cheat whether a cheat file for it already exists
# A subfolder "X" containing "X.m3u" or "X.cue" is one game, as in NextUI.
build_roms_list() {
  local rom_dir="$1" tag="$2" out="$3"
  local files="$CACHE_DIR/rom_files.txt" refs="$CACHE_DIR/rom_refs.txt" have="$CACHE_DIR/have_cheats.txt"

  find_rom_files "$rom_dir" > "$files"
  playlist_refs "$files" > "$refs"
  ls "$CHEATS_ROOT/$tag" > "$have" 2>/dev/null || : > "$have"

  jq -n --arg root "$rom_dir" --arg exts "$ROM_EXTENSIONS" \
    --rawfile files "$files" --rawfile refs "$refs" --rawfile have "$have" '
    def lines: split("\n") | map(sub("\r$"; "")) | map(select(. != ""));
    def dirname: sub("/[^/]*$"; "");
    def basename: sub("^.*/"; "");
    def stem: basename | sub("\\.[^.]*$"; "");
    def set: map({key: ., value: true}) | from_entries;

    ($refs | lines | map(gsub("/(\\./)+"; "/") | ascii_downcase) | set) as $referenced
    | ($have | lines | set) as $has
    | [$files | lines[] | select(test("\\.(" + $exts + ")$"; "i"))] as $roms
    | [ $roms[]
        | select(dirname != $root and stem == (dirname | basename)
                 and test("\\.(m3u|cue)$"; "i")) ]
      | group_by(dirname)
      | map(sort_by(test("\\.m3u$"; "i") | not) | .[0]) as $folder_games
    | ($folder_games | map(dirname + "/")) as $game_dirs
    | [ ($folder_games[] | {name: (dirname | ltrimstr($root + "/")), file: .}),
        ($roms[]
         | . as $f
         | select(($f | ascii_downcase | in($referenced)) | not)
         | select(all($game_dirs[]; . as $d | $f | startswith($d) | not))
         | {name: ltrimstr($root + "/"), file: .}) ]
    | map(.game = (.file | basename))
    | map(.has_cheat = ($has[.game + ".cht"] // $has[(.game | sub("\\.[^.]*$"; "")) + ".cht"] // false))
    | { items: sort_by(.name | ascii_downcase) }
  ' > "$out"
}

# ── Cheat lists ───────────────────────────────────────────────────────────────

valid_index() {
  [ -f "$1" ] && jq -e --arg system "$2" --argjson format "$INDEX_FORMAT" \
    '.format == $format and .system == $system and (.commit | type) == "string" and (.files | type) == "array"' \
    "$1" > /dev/null 2>&1
}

# index_newer A B: true if index A was generated after index B
index_newer() {
  jq -n -e --slurpfile a "$1" --slurpfile b "$2" '$a[0].generated > $b[0].generated' > /dev/null 2>&1
}

# load_cheat_list SYSTEM
# Sets CHEAT_LIST to a processed cheat list for a Libretro system. The list of
# cheat files comes from, in order of preference:
#   1. the cached index, if younger than CACHE_TTL_HOURS
#   2. a freshly downloaded index
#   3. the newer of the expired cached index and the one bundled in the pak
load_cheat_list() {
  local system="$1" slug encoded idx bundled src
  slug=$(system_slug "$system")
  idx="$CACHE_DIR/index/$slug.json"
  bundled="$BUNDLED_INDEX_DIR/$system.json"
  CHEAT_LIST="$CACHE_DIR/lists/$slug.json"
  src=""

  if cache_expired "$idx" || ! valid_index "$idx" "$system"; then
    show_status "Updating cheat list for $system..."
    encoded=$(printf '%s' "$system" | jq -Rr @uri)
    if fetch "$CHEAT_INDEX_URL/$encoded.json" "$idx.new" 30 && valid_index "$idx.new" "$system"; then
      mv "$idx.new" "$idx"
      src="$idx"
    else
      rm -f "$idx.new"
      echo "Could not refresh the cheat index for $system; using an offline copy"
      if valid_index "$bundled" "$system" && { ! valid_index "$idx" "$system" || index_newer "$bundled" "$idx"; }; then
        src="$bundled"
      elif valid_index "$idx" "$system"; then
        src="$idx"
      fi
    fi
  else
    src="$idx"
  fi

  if [ -z "$src" ]; then
    show_message "Couldn't load cheats for $system. Check your Wi-Fi connection." 4
    return 1
  fi

  # Rebuild the processed list when the index or the processing code changed
  if ! jq -L "$JQ_LIB" -e --slurpfile idx "$src" \
      'include "cheats"; .format == cheats_format and .commit == $idx[0].commit' \
      "$CHEAT_LIST" > /dev/null 2>&1; then
    show_status "Preparing cheat list for $system..."
    if ! jq -L "$JQ_LIB" 'include "cheats"; cheat_list' "$src" > "$CHEAT_LIST.tmp"; then
      rm -f "$CHEAT_LIST.tmp"
      show_message "Error processing cheat list. Try again." 4
      return 1
    fi
    mv "$CHEAT_LIST.tmp" "$CHEAT_LIST"
  fi
  hide_status

  if [ "$(list_count "$CHEAT_LIST")" -eq 0 ]; then
    show_message "No cheats are available for $system." 4
    return 1
  fi
}

# cheat_url LIST FILE: raw download URL, pinned to the indexed commit
cheat_url() {
  jq -r --arg base "$LIBRETRO_RAW" --arg file "$2" \
    '"\($base)/\(.commit)/cht/\(.system | @uri)/\($file | @uri)"' "$1"
}

# ── Saving cheats ─────────────────────────────────────────────────────────────

# NextUI looks for "<game>.cht" first, e.g. "Pokemon (USA).gba.cht". v0.1.x
# saved "<game without extension>.cht", which NextUI only finds by wildcard.
cheat_path() {
  echo "$CHEATS_ROOT/$1/$2.cht"
}

has_cheat() {
  [ -f "$(cheat_path "$1" "$2")" ] || [ -f "$CHEATS_ROOT/$1/${2%.*}.cht" ]
}

# download_cheat LIST FILE TAG GAME: download a cheat and save it for a game
download_cheat() {
  local list="$1" file="$2" tag="$3" game="$4" tmp="$CACHE_DIR/download.cht" dest
  dest=$(cheat_path "$tag" "$game")
  fetch "$(cheat_url "$list" "$file")" "$tmp" 60 || return 1
  if ! grep -q 'cheats[[:space:]]*=' "$tmp"; then
    echo "Not a cheat file: $file"
    rm -f "$tmp"
    return 1
  fi
  mkdir -p "$CHEATS_ROOT/$tag" && mv "$tmp" "$dest" || return 1
  echo "Saved: $dest"
}

# ── Menus ─────────────────────────────────────────────────────────────────────

# pick_cheat_for_rom TAG GAME TITLE
# Lets the user choose a cheat for one game. Returns 0 if one was saved.
pick_cheat_for_rom() {
  local tag="$1" game="$2" title="$3"
  local ranked="$CACHE_DIR/ranked.json" state="$CACHE_DIR/cheat_state.json" sel file name

  jq -L "$JQ_LIB" --arg rom "$game" 'include "cheats"; ranked_for_rom($rom)' \
    "$CHEAT_LIST" > "$ranked" || return 1
  if [ "$(jq '.matched' "$ranked")" -eq 0 ]; then
    show_message "No close matches. Showing all cheats." 2
  fi

  display_list "$ranked" "$title" "$state" || return 1
  sel=$(selected_index "$state") || return 1
  file=$(jq -r --argjson i "$sel" '.items[$i].file // empty' "$ranked")
  name=$(jq -r --argjson i "$sel" '.items[$i].name' "$ranked")
  [ -z "$file" ] && return 1

  if has_cheat "$tag" "$game"; then
    confirm "Replace the existing cheat file for $game?" "REPLACE" "KEEP" || return 1
  fi

  show_status "Downloading $name..."
  if ! download_cheat "$CHEAT_LIST" "$file" "$tag" "$game"; then
    show_message "Download failed. Check your connection." 4
    return 1
  fi
  show_message "Cheat saved for $game!" 2
}

# bulk_download ROMS_JSON TAG
# Downloads cheats for every game without one that has a single confident
# match, then writes the games that need a manual pick to $CACHE_DIR/review.json.
bulk_download() {
  local roms="$1" tag="$2"
  local plan="$CACHE_DIR/plan.json" auto_tsv="$CACHE_DIR/auto.tsv" review="$CACHE_DIR/review.json"
  local total review_count none existing i=0 saved=0 failed=0 streak=0 file game summary

  show_status "Matching cheats..."
  jq -L "$JQ_LIB" --slurpfile c "$CHEAT_LIST" 'include "cheats"; bulk_plan($c[0])' "$roms" > "$plan" || {
    show_message "Error matching cheats. Try again." 4
    return 1
  }
  jq --slurpfile p "$plan" '{ items: [.items[$p[0].review[]]] }' "$roms" > "$review"
  total=$(jq '.auto | length' "$plan")
  review_count=$(jq '.review | length' "$plan")
  none=$(jq '.none' "$plan")
  existing=$(jq '.existing' "$plan")

  summary="$review_count need you to pick a cheat.
$none have no matching cheats.
$existing already have cheats."
  if [ "$total" -eq 0 ]; then
    show_notice "No games with a single confident match.
$summary"
    return 0
  fi
  confirm "Download cheats for $total games?
$summary" "DOWNLOAD" "CANCEL" || return 1

  jq -r --slurpfile r "$roms" '.auto[] | "\(.file)\t\($r[0].items[.rom].game)"' "$plan" > "$auto_tsv"
  while IFS="$TAB" read -r file game; do
    i=$((i + 1))
    show_status "Downloading cheats... $i of $total"
    if download_cheat "$CHEAT_LIST" "$file" "$tag" "$game"; then
      saved=$((saved + 1))
      streak=0
    else
      failed=$((failed + 1))
      streak=$((streak + 1))
      # Several failures in a row almost always means the network is down
      if [ $streak -ge 3 ] && [ $saved -eq 0 ]; then
        break
      fi
    fi
  done < "$auto_tsv"
  hide_status

  if [ $saved -eq 0 ] && [ $failed -gt 0 ]; then
    show_message "Downloads failed. Check your connection." 4
    return 1
  fi
  show_notice "Saved cheats for $saved games.$([ $failed -gt 0 ] && printf '\n%s failed.' "$failed")
$review_count need you to pick a cheat."
}

# review_menu TAG: go through the games bulk_download couldn't decide on
review_menu() {
  local tag="$1" review="$CACHE_DIR/review.json" state="$CACHE_DIR/review_state.json" sel game count

  while true; do
    count=$(list_count "$review")
    [ "$count" -eq 0 ] && return 0
    display_list "$review" "Pick cheats ($count left)" "$state" || return 0
    sel=$(selected_index "$state") || return 0
    game=$(jq -r --argjson i "$sel" '.items[$i].game' "$review")
    if pick_cheat_for_rom "$tag" "$game" "$game"; then
      jq --argjson i "$sel" 'del(.items[$i])' "$review" > "$review.tmp" && mv "$review.tmp" "$review"
    fi
  done
}

# rom_menu SYSTEMS_JSON INDEX
rom_menu() {
  local systems="$1" idx="$2"
  local roms="$CACHE_DIR/roms.json" state="$CACHE_DIR/rom_state.json"
  local title tag rom_dir rc sel game

  title=$(jq -r --argjson i "$idx" '.items[$i].name' "$systems")
  tag=$(jq -r --argjson i "$idx" '.items[$i].short' "$systems")
  rom_dir=$(jq -r --argjson i "$idx" '.items[$i].rom_dir' "$systems")

  build_roms_list "$rom_dir" "$tag" "$roms"
  if [ "$(list_count "$roms")" -eq 0 ]; then
    show_message "No games found in $title" 3
    return 0
  fi

  while true; do
    display_list "$roms" "$title" "$state" --action-button X --action-text "GET ALL"
    rc=$?
    case $rc in
      0)
        sel=$(selected_index "$state") || continue
        game=$(jq -r --argjson i "$sel" '.items[$i].game' "$roms")
        pick_cheat_for_rom "$tag" "$game" "$(jq -r --argjson i "$sel" '.items[$i].name' "$roms")"
        ;;
      4)
        show_status "Scanning $title..."
        build_roms_list "$rom_dir" "$tag" "$roms"
        bulk_download "$roms" "$tag" && review_menu "$tag"
        build_roms_list "$rom_dir" "$tag" "$roms"
        ;;
      *) return 0 ;;
    esac
  done
}

main() {
  local systems="$CACHE_DIR/available_systems.json" state="$CACHE_DIR/sys_state.json" sel system

  show_status "Scanning ROM library..."
  build_available_systems "$systems"
  hide_status

  if [ "$(list_count "$systems")" -eq 0 ]; then
    show_message "No supported ROM folders found in $ROM_ROOT" 5
    return 0
  fi

  while true; do
    display_list "$systems" "Select System" "$state" || return 0
    sel=$(selected_index "$state") || continue
    system=$(jq -r --argjson i "$sel" '.items[$i].system' "$systems")
    load_cheat_list "$system" || continue
    rom_menu "$systems" "$sel"
  done
}
