#!/usr/bin/env bash
# Runs bootstrap.sh + playbooks/site.yml inside a privileged systemd Ubuntu container,
# checks idempotence, then runs tests/verify.yml.
#
#   UBUNTU_VERSION=22.04 tests/run.sh   # test another release (default 24.04)
#   KEEP=1 tests/run.sh                 # leave the container running for inspection
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ubuntu_version="${UBUNTU_VERSION:-24.04}"
image="plus-lan-server-test:${ubuntu_version}"
container="plus-lan-server-test-${ubuntu_version//./}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

cleanup() {
  if [[ "${KEEP:-0}" == "1" ]]; then
    echo "Container kept: docker exec -it ${container} bash"
  else
    docker rm -f -v "$container" >/dev/null 2>&1 || true
  fi
}

log "Building test image ${image}"
docker build --build-arg "UBUNTU_VERSION=${ubuntu_version}" -t "$image" "$repo_root/tests"

docker rm -f -v "$container" >/dev/null 2>&1 || true
trap cleanup EXIT

log "Starting ${container}"
# Docker/containerd state gets its own volumes: overlayfs can't be nested on the container's overlayfs.
docker run -d --name "$container" --privileged \
  --tmpfs /run --tmpfs /run/lock \
  -v /var/lib/docker -v /var/lib/containerd \
  -v "$repo_root:/workspace:ro" \
  "$image" >/dev/null

docker exec "$container" systemctl is-system-running --wait >/dev/null || true

run() { docker exec -w /workspace "$container" "$@"; }

log "bootstrap.sh"
run bash bootstrap.sh

log "Syntax check"
run ansible-playbook playbooks/site.yml --syntax-check

log "Converge"
run ansible-playbook playbooks/site.yml

log "Idempotence"
idempotence_log="$(run ansible-playbook playbooks/site.yml)"
echo "$idempotence_log"
if grep -Eq 'changed=[1-9]' <<<"$idempotence_log"; then
  echo "FAIL: second run reported changes" >&2
  exit 1
fi

log "Verify"
run ansible-playbook tests/verify.yml

log "All checks passed on Ubuntu ${ubuntu_version}"
