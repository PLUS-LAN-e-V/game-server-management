#!/usr/bin/env bash
# Entrypoint of the factorio service, wraps the image's /docker-entrypoint.sh.
#
# 1. Installs factorio/mod-list.json from the repo (copied, not mounted: the image rewrites the
#    file with mv, and Factorio drops entries for mods it can't find).
# 2. Downloads the enabled mods from the mod portal (image's /docker-update-mods.sh, needs the
#    username/token secrets).
# 3. Refuses to start while an enabled mod is missing. Otherwise Factorio would start without it,
#    and on the first start generate a map without the mods.
set -euo pipefail

mkdir -p "$MODS"
cp /mod-list.json "$MODS/mod-list.json"

# update-mods.sh is called with a relative path.
cd /
/docker-update-mods.sh

# Built into the game, no zip in mods/.
builtin='^(base|elevated-rails|quality|space-age)$'
missing=0
while read -r mod; do
  if [[ ! $mod =~ $builtin ]] && ! compgen -G "$MODS/${mod}_*.zip" >/dev/null; then
    echo "Mod $mod is missing in $MODS (download failed, see above)." >&2
    missing=1
  fi
done < <(jq -r '.mods[] | select(.enabled) | .name' "$MODS/mod-list.json")
if ((missing)); then
  echo "Not starting Factorio. Check FACTORIO_USERNAME / FACTORIO_TOKEN in .env." >&2
  exit 1
fi

# Mods are already downloaded above.
UPDATE_MODS_ON_START=false exec /docker-entrypoint.sh "$@"
