# Name parsing, display names and match ranking for libretro cheat files and
# ROM files. Loaded with `jq -L <pak>/lib 'include "cheats"; ...'` both on the
# device and in tests, so ROM and cheat names are always normalized by the
# same code.
#
# Names follow No-Intro conventions:
#   "Pokemon - Crystal Version (USA, Europe) (Rev 1) (GameShark)"
#    title                      region          extra   tool
# Older GoodTools-style ROM names such as "Game (U) [!]" are handled too.

# Bump when the shape of the processed cheat list changes, so device caches
# built by an older version are rebuilt.
def cheats_format: 2;

def tool_codes: {
  "actionreplay": "AR",
  "proactionreplay": "PAR",
  "gameshark": "GS",
  "gamegenie": "GG",
  "gamebuster": "GBu",
  "codebreaker": "CB",
  "xploder": "XP"
};

def region_codes: {
  "USA": "US", "Europe": "EU", "European": "EU", "Japan": "JP",
  "Japanese": "JP", "World": "WD", "Korea": "KR", "Brazil": "BR",
  "Germany": "DE", "France": "FR", "Spain": "ES", "Italy": "IT",
  "Australia": "AU", "Asia": "AS", "Netherlands": "NL", "China": "CN",
  "Taiwan": "TW", "Hong Kong": "HK", "Russia": "RU", "Canada": "CA",
  "Sweden": "SE", "Scandinavia": "SC", "Unknown": "??"
};

# GoodTools single-letter region codes, e.g. "(U)", "(JU)".
def goodtools_codes: {"U": "US", "E": "EU", "J": "JP", "W": "WD", "K": "KR"};

def strip_ws: gsub("^\\s+|\\s+$"; "");

def fold_accents:
  gsub("[àáâãäåÀÁÂÃÄÅ]"; "a") | gsub("[èéêëÈÉÊË]"; "e")
  | gsub("[ìíîïÌÍÎÏ]"; "i") | gsub("[òóôõöøÒÓÔÕÖØ]"; "o")
  | gsub("[ùúûüÙÚÛÜ]"; "u") | gsub("[ñÑ]"; "n") | gsub("[çÇ]"; "c");

# Lowercase alphanumeric form used for all comparisons.
def squash: fold_accents | ascii_downcase | gsub("&"; "and") | gsub("[^a-z0-9]"; "");

# Title comparison key. Treats "Legend of Zelda, The - X" and
# "The Legend of Zelda - X" as the same title.
def title_key:
  fold_accents | ascii_downcase
  | gsub(",\\s*the(?=\\s|$|[-:])"; "")
  | sub("^the\\s+"; "")
  | squash;

# "Name (A) (B) [!]" -> {title: "Name", tags: ["A", "B"], flags: ["!"]}
def split_name:
  { flags: [scan("\\[([^\\]]*)\\]") | .[0] | strip_ws] }
  + (gsub("\\[[^\\]]*\\]"; "")
     | { title: (sub("\\s*\\(.*$"; "") | strip_ws),
         tags: [scan("\\(((?:[^()]|\\([^()]*\\))*)\\)") | .[0] | strip_ws] });

# Classify one parenthesised tag as a cheat tool, region list, language list
# or anything else (revision, "Demo", "SGB Enhanced", ...).
def classify_tag:
  . as $t
  | (ascii_downcase | gsub("[^a-z]"; "")) as $sq
  | ($t | split(",") | map(strip_ws)) as $parts
  | if tool_codes[$sq] then {kind: "tool", value: tool_codes[$sq]}
    elif ($parts | length > 0 and all(.[]; region_codes[.] != null)) then
      {kind: "region", value: ($parts | map(region_codes[.]))}
    elif ($t | test("^[UEJWK]{1,3}$")) then
      {kind: "region", value: ($t | split("") | map(goodtools_codes[.]))}
    elif ($t | test("^[A-Z][a-z](\\s*[,+]\\s*[A-Z][a-z])*$")) then {kind: "lang", value: $t}
    else {kind: "other", value: $t} end;

def uniq_ordered: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);

# Parse a base name (no file extension) into its matching metadata.
def name_meta:
  . as $raw
  | split_name as $p
  | ($p.tags | map(classify_tag)) as $c
  | {
      title: $p.title,
      tool: ([$c[] | select(.kind == "tool") | .value] | first // ""),
      regions: ([$c[] | select(.kind == "region") | .value[]] | uniq_ordered),
      extras: [$c[] | select(.kind == "other") | .value],
      langs: [$c[] | select(.kind == "lang") | .value],
      flags: $p.flags
    }
  # A name that is all tags, e.g. "(Unnamed)": show it as-is
  | if .title == "" then .title = $raw | .extras = [] | .langs = [] | .flags = [] else . end
  | .key = (.title | title_key)
  | .variant = ([.key, (.regions | sort | join(",")),
                 (.extras | map(squash) | join(",")),
                 (.langs | map(squash) | sort | join(","))] | join("|"));

def strip_ext: sub("\\.[A-Za-z0-9]{1,5}$"; "");

def rom_meta: strip_ext | name_meta;

# "[GS|US,EU] Pokemon - Crystal Version (Rev 1)"
# $detailed also shows language and [flag] tags, used only when the short
# form would be ambiguous.
def display_name($detailed):
  ([.tool, (.regions | join(","))] | map(select(. != "")) | join("|")) as $prefix
  | (if $prefix == "" then "" else "[" + $prefix + "] " end)
    + .title
    + (.extras | map(" (" + . + ")") | join(""))
    + (if $detailed then (.langs | map(" (" + . + ")") | join(""))
                         + (.flags | map(" [" + . + "]") | join(""))
       else "" end);
def display_name: display_name(false);

# Index file ({commit, system, files: [...]}) -> processed cheat list used by
# the menus. Every display name is unique so similar files can be told apart.
def cheat_list:
  . as $idx
  | [ $idx.files[]
      | select(endswith(".cht"))
      | . as $file
      | (rtrimstr(".cht") | name_meta) as $m
      | { name: ($m | display_name), long: ($m | display_name(true)),
          file: $file, key: $m.key, variant: $m.variant, regions: $m.regions } ]
  | group_by(.name)
  | map(if length == 1 then . else map(.name = .long) end)
  | add // []
  | group_by(.name)
  | map(if length == 1 then .[0]
        else to_entries | map(.value + {name: "\(.value.name) #\(.key + 1)"}) | .[] end)
  | map(del(.long))
  | { format: cheats_format, commit: $idx.commit, system: $idx.system,
      items: sort_by(.name | ascii_downcase) };

# How well a processed cheat item matches a ROM's metadata. Lower is better:
#   0 exact (title, regions and revision/extra tags all match)
#   1 same title, compatible region
#   2 same title, different region
#   3 one title contains the other
#   4 no match
def match_tier($rom):
  .key as $key
  | if $rom.key == "" or $key == "" then 4
    elif .variant == $rom.variant then 0
    elif $key == $rom.key then
      # No region, "World" and "Unknown" are compatible with any region
      if ([.regions, $rom.regions] | any(.[]; length == 0 or any(.[]; . == "WD" or . == "??")))
         or any(.regions[]; IN($rom.regions[])) then 1 else 2 end
    elif ([$key, $rom.key] | map(length) | min) >= 4
         and (($key | contains($rom.key)) or ($rom.key | contains($key))) then 3
    else 4 end;

def tier_headers: {
  "0": "Best matches",
  "1": "Same game",
  "2": "Same game, other regions",
  "3": "Similar names",
  "4": "All other cheats"
};

# Processed cheat list -> minui-list items for one ROM file name, best matches
# first, grouped under header rows.
def ranked_for_rom($rom_name):
  ($rom_name | rom_meta) as $rom
  | [ .items[] | {name, file, tier: match_tier($rom)} ]
  | sort_by(.tier, (.name | ascii_downcase))
  | group_by(.tier)
  | map([{name: tier_headers[.[0].tier | tostring], is_header: true}] + .)
  | add // []
  | { items: ., matched: map(select(.tier != null and .tier < 4)) | length };

# Decide what "download all" does for each ROM in a roms list.
# Only a single candidate at the best tier (exact, or same title and
# compatible region) is downloaded automatically; everything else with a
# same-title candidate is left for the user to review.
#   $cheats: processed cheat list; input: roms list ({items: [...]})
def bulk_plan($cheats):
  (reduce $cheats.items[] as $c ({}; .[$c.key] += [$c])) as $by_key
  | reduce (.items | to_entries[]) as $e (
      {auto: [], review: [], none: 0, existing: 0};
      ($e.value.game | rom_meta) as $rom
      | if $e.value.has_cheat then .existing += 1
        else
          ([ ($by_key[$rom.key] // [])[] | {file, tier: match_tier($rom)} ]
           | map(select(.tier <= 2))) as $cands
          | ([$cands[] | select(.tier == 0)]) as $t0
          | ([$cands[] | select(.tier == 1)]) as $t1
          | if ($t0 | length) == 1 then .auto += [{rom: $e.key, file: $t0[0].file}]
            elif ($t0 | length) == 0 and ($t1 | length) == 1 then
              .auto += [{rom: $e.key, file: $t1[0].file}]
            elif ($cands | length) > 0 then .review += [$e.key]
            else .none += 1 end
        end
    );
