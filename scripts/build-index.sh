#!/bin/sh
# Builds the cheat index: one JSON file per Libretro system listing the .cht
# files in libretro-database, plus manifest.json. The device downloads these
# from raw.githubusercontent.com instead of calling the GitHub API, which caps
# directory listings at 1,000 files and allows 60 requests an hour.
#
# Usage: scripts/build-index.sh OUT_DIR [LIBRETRO_DATABASE_CHECKOUT]
# Without a checkout, a blobless clone (file names only, ~no file contents)
# is made in a temporary directory.
set -eu

# Must match INDEX_FORMAT in lib/common.sh
FORMAT=1

out="${1:?usage: build-index.sh OUT_DIR [LIBRETRO_DATABASE_CHECKOUT]}"
src="${2:-}"
tmp=""

if [ -z "$src" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  src="$tmp/libretro-database"
  git clone --quiet --depth 1 --filter=blob:none --no-checkout \
    https://github.com/libretro/libretro-database.git "$src"
fi

commit=$(git -C "$src" rev-parse HEAD)
generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
builder=$(git hash-object "$0")

rm -rf "$out"
mkdir -p "$out"

git -C "$src" ls-tree -r --name-only HEAD cht/ \
  | jq -R -s -c --argjson format "$FORMAT" --arg commit "$commit" --arg generated "$generated" '
      split("\n")
      | map(select(startswith("cht/") and endswith(".cht")) | ltrimstr("cht/") | split("/"))
      | map(select(length == 2))
      | group_by(.[0])
      | .[]
      | { format: $format, commit: $commit, generated: $generated,
          system: .[0][0], files: map(.[1]) | sort }
    ' \
  | while IFS= read -r line; do
      system=$(printf '%s' "$line" | jq -r '.system')
      printf '%s\n' "$line" > "$out/$system.json"
    done

jq -n --argjson format "$FORMAT" --arg commit "$commit" --arg generated "$generated" \
  --arg builder "$builder" --arg dir "$out" '
    { format: $format, commit: $commit, generated: $generated, builder: $builder,
      systems: [$ARGS.positional[] | ltrimstr($dir + "/") | rtrimstr(".json")] | sort }
  ' --args "$out"/*.json > "$out/manifest.json.tmp"
mv "$out/manifest.json.tmp" "$out/manifest.json"

echo "Indexed $(jq '.systems | length' "$out/manifest.json") systems from libretro-database $commit"
