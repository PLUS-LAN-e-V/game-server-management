.PHONY: test test-all apply check

# Run the full container test (default Ubuntu 24.04; override with UBUNTU_VERSION=22.04).
test:
	tests/run.sh

test-all:
	UBUNTU_VERSION=22.04 tests/run.sh
	UBUNTU_VERSION=24.04 tests/run.sh

# On the server itself (after sudo ./bootstrap.sh):
apply:
	sudo ansible-playbook playbooks/site.yml --become=false

check:
	sudo ansible-playbook playbooks/site.yml --become=false --check --diff
