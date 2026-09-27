# Server Setup Instructions

The game servers run as one Docker Compose project (`plus-lan`). The OS and Docker itself are
set up by Ansible first; see the [top-level README](../README.md).

## First start

On the server, in this directory:

```bash
cp .env.example .env    # then fill in both passwords (letters and digits only)
docker compose up -d
```

Compose refuses to start the stack while a variable in `.env` is missing.

Runtime data goes to `data/<service>/`, backups to `backups/` (see [Backups](#backups)). Both
are gitignored. The first CS2 start downloads the full game (about 60 GB per instance), so it
takes a while.

Start or stop single services with `docker compose up -d <service>` / `docker compose stop <service>`.

## Services and ports

| Service | Game port | RCON / web | Notes |
|---|---|---|---|
| `cs2-01` | 27015 tcp+udp | RCON 27015/tcp | |
| `cs2-02` | 27016 tcp+udp | RCON 27016/tcp | Players join with `connect <server-ip>:27016` |
| `minecraft` | 25565 | BlueMap http://\<server-ip\>:8100 | RCON only inside the Compose network |
| `satisfactory` | 7777 tcp+udp, 8888 tcp | – | |
| `factorio` | 34197 udp | RCON 27030/tcp | |
| `backup` | – | – | Hourly backups of Minecraft, Factorio and Satisfactory |

## Counter-Strike 2

Both instances use LinuxGSM (`ghcr.io/gameservermanagers/gameserver:cs2`).

- **RCON:** `cs2/cs2server.cfg` is mounted into both containers as the LinuxGSM instance config.
  It adds `-usercon` (CS2 only accepts RCON with it) and `+rcon_password`, read from
  `CS2_RCON_PASSWORD` via a Compose secret. Connect with any Source RCON client to the game port.
- **Server name, password, maps:** edit the game config LinuxGSM creates on install,
  `data/cs2-0X/serverfiles/game/csgo/cfg/cs2server.cfg` (`hostname`, `sv_password`, `map`, ...).
- **Updates:** LinuxGSM checks for CS2 updates on container start and every 60 minutes, and
  restarts the server when an update is installed.
- **Console:** `docker exec -it --user linuxgsm pluslan-cs2-01 ./cs2server console`
  (detach with `Ctrl-b d`).

## Minecraft

Paper via `itzg/minecraft-server`. `VERSION` is intentionally unset, so every restart runs
the newest stable Paper release. Players need a matching client version.

- **Console:** `docker exec -it pluslan-minecraft rcon-cli`
- **BlueMap:** installed from Modrinth on startup. It is marked optional (`bluemap?`): when a
  new Minecraft release is out before BlueMap supports it, the server starts without the map.
  `minecraft/bluemap/core.conf` (mounted read-only) sets `accept-download: true`, which
  BlueMap needs to download the Minecraft client textures. Tiles render in the background
  while players explore.
- **Backups:** see [Backups](#backups).

## Factorio

`factoriotools/factorio:stable`, so players on the default (stable) client can connect.

- **Settings:** `factorio/server-settings.json` is mounted as the server config: LAN
  visibility only (public listing would need factorio.com credentials), name, autosaves, etc.
  Restart the service after changing it.
- **Space Age:** `DLC_SPACE_AGE: "true"` in `docker-compose.yml` means every player needs the
  DLC. Set it to `"false"` for base game only.
- **RCON:** host port 27030. The password is generated on first start in
  `data/factorio/config/rconpw`.
- **Admins:** `data/factorio/config/server-adminlist.json`.
- A new map is generated on first start when `data/factorio/saves/` is empty.
- **Backups:** see [Backups](#backups).

## Satisfactory

`wolveix/satisfactory-server`, limited to 12 GB RAM. The first player to connect claims the
server in-game and sets the admin password.

- **Saves, blueprints, server settings:** `data/satisfactory/saved/`.
- **Backups:** see [Backups](#backups). The image also copies `saved/server/` to
  `data/satisfactory/backups/` on every container start, but it overwrites files of the same
  name and keeps no history.

## Backups

CS2 servers are disposable and not backed up. Minecraft, Factorio and Satisfactory are
persistent worlds and are backed up by one coordinator service, `backup` (script: `backup/backup.sh`). It runs all
the time: first backup 5 minutes after it starts, then at every full hour.

| | Minecraft | Factorio | Satisfactory |
|---|---|---|---|
| How | RCON `save-off` → `save-all flush` → archive `data/minecraft` → `save-on` | Archive the existing saves plus `config/` and `mods/`. It never triggers a save. | Archive `saved/` (saves, blueprints, server settings) once no file has changed for 30 s. It never triggers a save. |
| When skipped | Nobody was online since the last backup. When the server is stopped: world unchanged since the last backup. | No new save since the last backup. Factorio only autosaves while someone plays, and saves on shutdown. | Nothing in `saved/` changed since the last backup. Files still changing (save in progress): retried next hour. |
| Excluded | BlueMap tiles, jars, logs, cache | Saves still being written (`*.tmp.zip`) | Game files and the image's own `backups/` copy |
| Files | `backups/minecraft/minecraft-<date>-<time>.tar.gz` | `backups/factorio/factorio-<date>-<time>.tar` | `backups/satisfactory/satisfactory-<date>-<time>.tar` |

Only Minecraft archives are compressed. Factorio saves (zip) and Satisfactory saves are already
compressed, so compressing them again would cost CPU and save almost nothing (about 5% for
Factorio in testing).

After the last player leaves, one more backup captures the final state. Stopping a server also
produces a final backup within the hour. The same happens if the server was stopped at LAN end.

**Effect on the game.** Factorio and Satisfactory freeze the game briefly for everyone while
they save, so the backup only copies the autosaves they make anyway. Factorio autosaves (every 10 minutes, `autosave_interval` in
`factorio/server-settings.json`), Satisfactory by default every 5 minutes. A backup can
therefore be up to one autosave interval behind the live game. Minecraft does one extra save pass per hour (the same work as Paper's own autosave).
World saving is paused only for the few seconds the archive takes, and the game keeps running
meanwhile. Archiving runs at the lowest CPU and IO priority.

**Retention.** Per game: every backup from the last 24 hours, plus the newest backup of each
older day (days in `Europe/Berlin` time). Older days are never deleted automatically; review
them before each LAN (see [EACH-LAN-START.md](../EACH-LAN-START.md)). A 4-day LAN leaves about
five archives per game once the hourly ones have been thinned out.

**Log.** Every run writes one line per game to `backups/backup.log` (also `docker logs
pluslan-backup`): `OK` with file and size, `SKIP` with the reason, `FAIL` with the error, and
`PRUNE` for deleted files.

```bash
tail -n 20 backups/backup.log
grep FAIL backups/backup.log
```

**Restore Minecraft:**

```bash
docker compose stop backup minecraft
mv data/minecraft/world data/minecraft/world.old   # likewise world_nether / world_the_end
tar -xzf backups/minecraft/minecraft-<date>-<time>.tar.gz -C data/minecraft
docker compose up -d minecraft backup
```

**Restore Factorio:** Factorio loads the newest save in `saves/`, so move the current saves
aside first:

```bash
docker compose stop backup factorio
mv data/factorio/saves data/factorio/saves.old
tar -xf backups/factorio/factorio-<date>-<time>.tar -C data/factorio saves
docker compose up -d factorio backup
```

**Restore Satisfactory:**

```bash
docker compose stop backup satisfactory
mv data/satisfactory/saved data/satisfactory/saved.old
tar -xf backups/satisfactory/satisfactory-<date>-<time>.tar -C data/satisfactory
docker compose up -d satisfactory backup
```

If the server doesn't come up with the restored save, load it in-game via
*Server Manager → Manage Saves*.

**Backups from the former `minecraft-backup` service** (`backups/minecraft/world-*.tar.gz`)
have the same layout. Rename them once so retention and restore treat them like the new ones:

```bash
cd backups/minecraft && for f in world-*.tar.gz; do mv "$f" "minecraft-${f#world-}"; done
```

## Updating images

```bash
docker compose pull
docker compose up -d
```
