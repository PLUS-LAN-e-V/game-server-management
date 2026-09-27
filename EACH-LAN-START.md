# Each LAN: Start

Checklist for the operator before each PLUS-LAN (twice a year, 4 days each).
Commands run in `server-management/` on the server.

## Backups

The `backup` service keeps every hourly backup of the last 24 hours plus one per older day,
and never deletes older days by itself. Daily backups from previous LANs (and from any play
between LANs) pile up until they are cleaned up here. Details: [server-management/SETUP.md](server-management/SETUP.md#backups).

- [ ] The backup service is running and the last runs were fine (recent `OK`/`SKIP` lines, no `FAIL`):
  ```bash
  docker compose ps backup
  tail -n 20 backups/backup.log
  grep FAIL backups/backup.log | tail
  ```
- [ ] Enough disk space for the LAN (CS2 alone needs ~60 GB per instance):
  ```bash
  df -h .
  du -sh backups/*
  ```
- [ ] Decide which old backups to keep, e.g. only the last backup of each previous LAN, and delete the rest:
  ```bash
  ls -lh backups/minecraft backups/factorio backups/satisfactory
  rm backups/<game>/<game>-<date>-<time>.tar*   # per file to delete
  ```
