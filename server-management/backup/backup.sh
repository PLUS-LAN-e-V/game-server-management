#!/usr/bin/env bash
# Backup coordinator for the persistent game worlds (Minecraft, Factorio, Satisfactory), run by
# the `backup` service. Backs up once after INITIAL_DELAY, then at every full BACKUP_INTERVAL_MINUTES.
#
# Minecraft: only while someone has played since the last backup (checked over RCON):
#            save-off -> save-all flush -> archive /data/minecraft -> save-on.
#            If the server is stopped, archive the world when it changed since the last backup.
# Factorio:  never triggers a save (every save freezes the game for all players). Archives the
#            newest completed autosave when it is newer than the last backup. Factorio autosaves
#            only while someone plays and also saves on shutdown.
# Satisfactory: same idea: never triggers a save, archives saved/ (saves, blueprints, server
#            settings) when something in it changed since the last backup. Waits until no file
#            was written for SAVE_QUIET_SECONDS, so a save in progress is never archived.
#
# Minecraft archives are gzip-compressed (.tar.gz). Factorio and Satisfactory saves are already
# compressed, so they are stored as plain .tar.
#
# Retention per game: every backup from the last 24 hours, plus the newest one of each older day.
# Older days are never deleted automatically; see EACH-LAN-START.md.
#
# Every result (OK with path and size, SKIP with reason, FAIL with reason) goes to stdout and
# to $BACKUP_ROOT/backup.log.
set -uo pipefail

: "${BACKUP_ROOT:=/backups}"
: "${DATA_ROOT:=/data}"
: "${INITIAL_DELAY:=5m}"
: "${BACKUP_INTERVAL_MINUTES:=60}"
: "${MINECRAFT_RCON_HOST:=minecraft}"
: "${MINECRAFT_RCON_PORT:=25575}"
: "${MINECRAFT_RCON_PASSWORD:?MINECRAFT_RCON_PASSWORD must be set}"
: "${SAVE_QUIET_SECONDS:=30}"

# BlueMap tiles are large and re-rendered from the world; jars/libraries are re-downloaded.
MINECRAFT_EXCLUDES=(--exclude='*.jar' --exclude='cache' --exclude='logs' --exclude='*.tmp' --exclude='bluemap/web/maps')

log_file="$BACKUP_ROOT/backup.log"

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S %Z') $*"
  echo "$line"
  echo "$line" >>"$log_file"
}

# archive <game> <tar.gz|tar> <source dir> <tar args...>
# Writes $BACKUP_ROOT/<game>/<game>-<timestamp>.<ext> at low CPU/IO priority so the game
# servers keep priority. Logs the result.
archive() {
  local game="$1" ext="$2" src="$3"
  shift 3
  local dir="$BACKUP_ROOT/$game" name start out tmp err compress=()
  [[ $ext == tar.gz ]] && compress=(-z)
  start="$(date +%s)"
  name="$game-$(date +%Y%m%d-%H%M%S).$ext"
  out="$dir/$name"
  tmp="$dir/.$name.partial" # hidden, so it never counts as a backup
  mkdir -p "$dir"
  if err="$(nice -n 19 ionice -c 3 tar "${compress[@]}" -cf "$tmp" -C "$src" "$@" 2>&1)"; then
    mv "$tmp" "$out"
    log "$game OK    $out ($(du -h "$out" | cut -f1), $(($(date +%s) - start))s)"
    return 0
  fi
  rm -f "$tmp"
  log "$game FAIL  tar failed: ${err//$'\n'/ }"
  return 1
}

# All backups of <game>, oldest first (names sort chronologically).
backups_of() {
  ls -1 "$BACKUP_ROOT/$1/$1"-*.tar "$BACKUP_ROOT/$1/$1"-*.tar.gz 2>/dev/null | sort
}

latest_backup() {
  backups_of "$1" | tail -1
}

# prune <game>: keep everything from the last 24h and the newest backup of each older day.
prune() {
  local game="$1" cutoff prev_day="" f ts day
  cutoff="$(date -d '24 hours ago' +%Y%m%d-%H%M%S)"
  # Newest first; names sort chronologically.
  for f in $(backups_of "$game" | sort -r); do
    ts="${f##*/"$game"-}"
    ts="${ts%%.tar*}"
    [[ $ts > $cutoff ]] && continue
    day="${ts%%-*}"
    if [[ $day == "$prev_day" ]]; then
      rm -f "$f" && log "$game PRUNE $f"
    else
      prev_day="$day"
    fi
  done
}

mc_rcon() {
  rcon-cli --host "$MINECRAFT_RCON_HOST" --port "$MINECRAFT_RCON_PORT" --password "$MINECRAFT_RCON_PASSWORD" "$@"
}

backup_minecraft() {
  local src="$DATA_ROOT/minecraft" flag="$BACKUP_ROOT/minecraft/.players-at-last-backup"
  local reply players latest status
  latest="$(latest_backup minecraft)"

  if ! (exec 3<>"/dev/tcp/$MINECRAFT_RCON_HOST/$MINECRAFT_RCON_PORT") 2>/dev/null; then
    # Server stopped: files are complete and not being written.
    if [[ ! -d $src/world ]]; then
      log "minecraft SKIP  no world in $src and server not reachable"
    elif [[ -n $latest && -z "$(find "$src"/world* -newer "$latest" -type f -print -quit 2>/dev/null)" ]]; then
      log "minecraft SKIP  server not reachable and world unchanged since $latest"
    else
      log "minecraft INFO  server not reachable, archiving the world as it is on disk"
      archive minecraft tar.gz "$src" "${MINECRAFT_EXCLUDES[@]}" .
    fi
    return
  fi

  # Server is up: never archive without save-off, so an RCON error (e.g. wrong password) is a failure.
  if ! reply="$(mc_rcon list 2>&1)"; then
    log "minecraft FAIL  RCON error, is MINECRAFT_RCON_PASSWORD correct? ${reply//$'\n'/ }"
    return
  fi

  # "There are 0 of a max of 40 players online: ..."
  players="$(grep -o 'There are [0-9]*' <<<"$reply" | grep -o '[0-9][0-9]*')"
  players="${players:-1}" # unexpected reply: rather back up than skip
  if ((players == 0)) && [[ ! -f $flag && -n $latest ]]; then
    log "minecraft SKIP  no players since the last backup"
    return
  fi

  if ! reply="$(mc_rcon save-off 2>&1)"; then
    log "minecraft FAIL  save-off failed: ${reply//$'\n'/ }"
    return
  fi
  if reply="$(mc_rcon 'save-all flush' 2>&1)"; then
    sync
    archive minecraft tar.gz "$src" "${MINECRAFT_EXCLUDES[@]}" .
    status=$?
  else
    log "minecraft FAIL  save-all failed: ${reply//$'\n'/ }"
    status=1
  fi
  # Always re-enable saving, even when the backup failed.
  if ! reply="$(mc_rcon save-on 2>&1)"; then
    log "minecraft FAIL  save-on failed, world saving may still be OFF: ${reply//$'\n'/ }"
  fi

  if ((status == 0)); then
    if ((players > 0)); then touch "$flag"; else rm -f "$flag"; fi
  fi
}

backup_factorio() {
  local src="$DATA_ROOT/factorio" latest
  if ! compgen -G "$src/saves/*.zip" >/dev/null; then
    log "factorio SKIP  no saves in $src/saves"
    return
  fi
  latest="$(latest_backup factorio)"
  if [[ -n $latest && -z "$(find "$src/saves" -maxdepth 1 -name '*.zip' ! -name '*.tmp.zip' -newer "$latest" -print -quit)" ]]; then
    log "factorio SKIP  no new save since $latest"
    return
  fi
  # *.tmp.zip is a save in progress; completed saves are renamed atomically.
  archive factorio tar "$src" --exclude='*.tmp.zip' saves config mods
}

# Satisfactory writes saves in place, so wait until nothing under <dir> changed for
# SAVE_QUIET_SECONDS (at most 4 tries). Returns 1 if files keep changing.
wait_until_quiet() {
  local dir="$1" try newest
  for try in 1 2 3 4; do
    # BusyBox find has no -newermt: compare the newest mtime with the clock instead.
    newest="$(find "$dir" -type f -exec stat -c %Y {} + | sort -n | tail -1)"
    (($(date +%s) - ${newest:-0} >= SAVE_QUIET_SECONDS)) && return 0
    sleep "$SAVE_QUIET_SECONDS"
  done
  return 1
}

backup_satisfactory() {
  local src="$DATA_ROOT/satisfactory" latest
  if [[ -z "$(find "$src/saved/server" -type f -name '*.sav' -print -quit 2>/dev/null)" ]]; then
    log "satisfactory SKIP  no saves in $src/saved/server"
    return
  fi
  latest="$(latest_backup satisfactory)"
  if [[ -n $latest && -z "$(find "$src/saved" -type f -newer "$latest" -print -quit)" ]]; then
    log "satisfactory SKIP  nothing saved since $latest"
    return
  fi
  if ! wait_until_quiet "$src/saved"; then
    log "satisfactory SKIP  files in $src/saved kept changing (save in progress?), retrying next run"
    return
  fi
  archive satisfactory tar "$src" saved
}

mkdir -p "$BACKUP_ROOT"
interval=$((BACKUP_INTERVAL_MINUTES * 60))
log "backup coordinator started (initial delay ${INITIAL_DELAY}, then every ${BACKUP_INTERVAL_MINUTES} min)"
sleep "$INITIAL_DELAY"

while true; do
  backup_minecraft
  prune minecraft
  backup_factorio
  prune factorio
  backup_satisfactory
  prune satisfactory
  # Sleep until the next full interval (e.g. top of the hour).
  sleep $((interval - $(date +%s) % interval))
done
