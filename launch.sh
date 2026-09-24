#!/bin/sh
# Another Cheat Downloader. A MinUI pak for downloading cheat files from the Libretro database
# Mike Cosentino

PAK_DIR="$(cd "$(dirname "$0")" && pwd)"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
PLATFORM="${PLATFORM:-tg5040}"
export PATH="$PAK_DIR/bin/$PLATFORM:$PATH"

# shellcheck source=lib/common.sh
. "$PAK_DIR/lib/common.sh"
init_config

set -x
mkdir -p "$LOGS_PATH"
rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >>"$LOGS_PATH/$PAK_NAME.txt"
exec 2>&1

trap hide_status EXIT
main
