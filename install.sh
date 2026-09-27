#!/usr/bin/env bash
# Clone the PLUS-LAN server repository on a fresh Ubuntu host and install Ansible.
# Usage: curl -fsSL <raw-install-url> | sudo bash -s -- <git-repository-url> [git-ref]
set -euo pipefail

repo_url="${1:-}"
repo_ref="${2:-${REPO_REF:-main}}"
install_dir="${INSTALL_DIR:-/opt/plus-lan-server}"

if [[ -z "$repo_url" ]]; then
  echo "Usage: curl -fsSL <raw-install-url> | sudo bash -s -- <git-repository-url> [git-ref]" >&2
  exit 2
fi

if [[ $EUID -ne 0 ]]; then
  echo "install.sh must run as root (use sudo)" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]] || ! . /etc/os-release || [[ ${ID:-} != ubuntu ]]; then
  echo "install.sh supports Ubuntu only" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

if ! command -v git >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends git
fi

if [[ -e "$install_dir" && ! -d "$install_dir/.git" ]]; then
  echo "Refusing to use existing non-Git directory: $install_dir" >&2
  exit 1
fi

if [[ -d "$install_dir/.git" ]]; then
  echo "Using existing checkout: $install_dir"
else
  mkdir -p "$(dirname "$install_dir")"
  git clone --branch "$repo_ref" --depth 1 "$repo_url" "$install_dir"
fi

cd "$install_dir"
./bootstrap.sh

cat <<EOF

Ansible is installed and the repository is available at:
  $install_dir

Next steps:
  cd $install_dir
  make apply
  cd server-management
  cp .env.example .env
  # Fill in both RCON passwords, then:
  docker compose up -d
EOF
