# plus-lan-server

Infrastructure as code for the PLUS-LAN server (Ubuntu).

- **Ansible** configures the OS: base packages, Docker Engine and the Docker Compose plugin.
- **Docker Compose** runs the game servers: 2× Counter-Strike 2, Minecraft (Paper + BlueMap),
  Satisfactory and Factorio, plus an hourly backup service for the Minecraft, Factorio and
  Satisfactory worlds. See [server-management/SETUP.md](server-management/SETUP.md).

```
install.sh              clones the repo and installs Ansible on a fresh Ubuntu server
bootstrap.sh            installs Ansible on the server
playbooks/, roles/      OS configuration (roles: common, docker)
inventory/              target host and its variables
tests/                  container-based test of the playbooks
server-management/      docker-compose.yml, versioned game configs, backup script, game server docs
EACH-LAN-START.md       operator checklist before each LAN
```

## 0. Install from a remote repository

On a fresh Ubuntu server, run the installer as root. Pass the public Git repository URL
explicitly; the installer installs Git when needed, clones into `/opt/plus-lan-server`, and
runs `bootstrap.sh`.

```sh
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh \
    | sudo bash -s -- https://github.com/<owner>/<repo>.git

wget -qO- https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh \
    | sudo bash -s -- https://github.com/<owner>/<repo>.git
```

The install directory and Git ref can be overridden with `INSTALL_DIR` and `REPO_REF`. The
installer does not apply the Ansible playbook automatically; continue with `make apply` below.

## 1. Set up the server (Ansible)

On the Ubuntu server, with this repo checked out:

```sh
sudo ./bootstrap.sh   # installs Ansible from the official PPA
make apply            # ansible-playbook playbooks/site.yml --ask-become-pass
```

`make check` does a dry run (`--check --diff`).

To manage the server from another machine over SSH instead, edit `inventory/hosts.yml`
(remove `ansible_connection: local`, set `ansible_host`/`ansible_user`).

Users that should run `docker` without sudo go in `docker_users` in
`inventory/group_vars/lan_servers.yml`.

## 2. Start the game servers (Docker Compose)

```sh
cd server-management
cp .env.example .env   # fill in the RCON passwords
docker compose up -d
```

Ports, RCON, backups and per-game configuration are documented in
[server-management/SETUP.md](server-management/SETUP.md).

## Testing the Ansible playbooks

Needs Docker on your machine; Ansible does not have to be installed locally.

```sh
make test          # Ubuntu 24.04
make test-all      # Ubuntu 22.04 and 24.04
KEEP=1 make test   # keep the container afterwards for poking around
```

`tests/run.sh` starts a privileged Ubuntu container with systemd, runs `bootstrap.sh`,
applies `playbooks/site.yml` twice (the second run must report `changed=0`), then runs the
checks in `tests/verify.yml`.
