#!/usr/bin/env bash
# Installs Ansible on a fresh Ubuntu host so the playbooks in this repo can run.
# Usage: sudo ./bootstrap.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "bootstrap.sh must run as root (use sudo)" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends software-properties-common gpg-agent

# The official Ansible PPA gives the same recent Ansible on every supported Ubuntu release.
add-apt-repository -y --update ppa:ansible/ansible
apt-get install -y ansible

ansible --version
