# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Ansible IaC for a single Ubuntu game/LAN server. Split of responsibilities:
- **Ansible (this repo's roles)**: OS configuration only — base packages, Docker Engine + Compose plugin, and future OS-level concerns.
- **Docker Compose**: all applications (CS2, Minecraft, Factorio, Satisfactory, TeamSpeak 3, backups). Don't install apps directly on the host via Ansible; deploy them as Compose stacks.

The Compose stack is `server-management/docker-compose.yml` (CS2 ×2 via LinuxGSM, Minecraft/Paper + BlueMap, Satisfactory, Factorio, TeamSpeak 3, and a `backup` coordinator). Game config that should be versioned lives next to it (`cs2/`, `minecraft/`, `factorio/`) and is bind-mounted over the path inside the container's data volume; runtime state goes to `data/` and `backups/` (gitignored). Secrets come from `server-management/.env` (template: `.env.example`). Before mounting a file, check the image's entrypoint: some `chown -R` their data dir (a `:ro` mount then aborts startup under `set -e`, e.g. Factorio), and some only generate a config if it's missing. Minecraft always runs the newest stable Paper (no `VERSION` pin), so Modrinth plugins must be marked optional with `?`. Backups: `server-management/backup/backup.sh` runs in the `backup` service (the `itzg/mc-backup` image is only a toolbox for bash/tar/rcon-cli; its `find` is BusyBox, no `-newermt`). CS2 is ephemeral and not backed up; TeamSpeak isn't either. The script must not add game-loop load: Factorio and Satisfactory saves freeze the game, so it only copies their existing autosaves and never triggers a save (Satisfactory writes saves in place, hence the quiet-period check); Minecraft is only archived between `save-off` and `save-on`, never while the server is up without them. Retention is every backup from the last 24h plus one per older day, and older days are cleaned up manually (`EACH-LAN-START.md`). `server-management/SETUP.md` is the operator doc (ports table, RCON, backups, per-game config); update it and the service list in `README.md` whenever services, ports or mounted configs change. Top-level `EACH-LAN-START.md` / `EACH-LAN-STOP.md` are runbooks for before and after each LAN event, and `TODO.md` is the backlog. They are still being written; manual steps in them are candidates for automation.

Target OS is always Ubuntu (tested on 22.04 and 24.04). No need to support other distros.

## Commands

```sh
make test                         # full container test on Ubuntu 24.04 (needs only local Docker)
UBUNTU_VERSION=22.04 tests/run.sh # single other release
make test-all                     # 22.04 + 24.04
KEEP=1 make test                  # keep container; then: docker exec -it plus-lan-server-test-2404 bash
make apply / make check           # on the server itself, after `sudo ./bootstrap.sh`
```

Ansible is not installed on the dev Mac — run everything through `tests/run.sh`, or `docker exec` into a kept test container (repo is mounted read-only at `/workspace`).

## How the pieces fit

- `bootstrap.sh` installs Ansible from `ppa:ansible/ansible` (same recent ansible-core on every Ubuntu release; the full `ansible` package, so community collections like `community.docker` are available without a `requirements.yml`).
- `ansible.cfg` sets the inventory and `become = true` globally. `inventory/hosts.yml` defaults to `ansible_connection: local` (run on the server itself); switching to SSH is an inventory-only change.
- `playbooks/site.yml` applies roles to the `lan_servers` group. New OS roles go in `roles/<name>/` and get added there.
- Role defaults live in `roles/*/defaults/main.yml`; site-specific overrides go in `inventory/group_vars/lan_servers.yml`.
- The `docker` role follows Docker's official Ubuntu install (removes conflicting distro packages, adds the repo via `deb822_repository`, which needs `python3-debian`).

## Testing model

`tests/run.sh` treats a privileged systemd container (`tests/Dockerfile`) as the server: bootstrap → syntax check → converge → second converge must report `changed=0` → `tests/verify.yml`.
- Every task must be idempotent; the idempotence step fails the test otherwise. Give `command`/`shell` tasks `changed_when`/`creates`.
- Add end-state assertions for new roles to `tests/verify.yml`.
- `/var/lib/docker` and `/var/lib/containerd` are separate volumes in the test container because nested overlayfs fails; this is test-only and roles must not special-case containers.
