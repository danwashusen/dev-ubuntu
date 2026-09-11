SHELL := /bin/bash
.DEFAULT_GOAL := help

PRLCTL ?= /usr/local/bin/prlctl
DOWNLOADS_DIR ?=
SIZING_VM ?=
VM_NAME ?=
IMAGE ?=
CPUS ?=
MEMORY_MB ?=
DISK_GB ?=
START_VM ?=
RESUME ?= no
AUTOINSTALL ?= yes
GUEST_USER ?=
GUEST_HOSTNAME ?=
SSH_PUBLIC_KEY ?=
ARTIFACTS_DIR ?=
WAIT_FOR_SSH ?= yes
SSH_HOST ?=
SSH_WAIT_TIMEOUT ?= 2700
RUN_ANSIBLE ?= yes
ANSIBLE_PLAYBOOK ?=
BECOME_ARGS ?= --ask-become-pass
PLAYBOOK_ARGS ?=
DEVELOPER_EXTRA_TASKS_FILE ?=

.PHONY: help bootstrap apply-playbook images vms

help: ## Show available targets and overrides
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "%-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

bootstrap: ## Interactively create an ARM64 Ubuntu VM from an ISO
	@./scripts/bootstrap-vm.sh \
		--prlctl "$(PRLCTL)" \
		--downloads "$(DOWNLOADS_DIR)" \
		--sizing-vm "$(SIZING_VM)" \
		--name "$(VM_NAME)" \
		--image "$(IMAGE)" \
		--cpus "$(CPUS)" \
		--memory-mb "$(MEMORY_MB)" \
		--disk-gb "$(DISK_GB)" \
		--start "$(START_VM)" \
		--resume "$(RESUME)" \
		--autoinstall "$(AUTOINSTALL)" \
		--guest-user "$(GUEST_USER)" \
		--hostname "$(GUEST_HOSTNAME)" \
		--ssh-key "$(SSH_PUBLIC_KEY)" \
		--artifacts "$(ARTIFACTS_DIR)" \
		--wait-for-ssh "$(WAIT_FOR_SSH)" \
		--ssh-host "$(SSH_HOST)" \
		--ssh-timeout "$(SSH_WAIT_TIMEOUT)" \
		--run-ansible "$(RUN_ANSIBLE)" \
		--ansible "$(ANSIBLE_PLAYBOOK)" \
		--developer-extra-tasks "$(DEVELOPER_EXTRA_TASKS_FILE)"

apply-playbook: ## Apply site.yml to an existing bootstrapped Parallels VM
	@./scripts/apply-playbook.sh \
		--prlctl "$(PRLCTL)" \
		--name "$(VM_NAME)" \
		--guest-user "$(GUEST_USER)" \
		--ssh-host "$(SSH_HOST)" \
		--ssh-key "$(SSH_PUBLIC_KEY)" \
		--ssh-timeout "$(SSH_WAIT_TIMEOUT)" \
		--ansible "$(ANSIBLE_PLAYBOOK)" \
		--developer-extra-tasks "$(DEVELOPER_EXTRA_TASKS_FILE)" \
		-- $(BECOME_ARGS) $(PLAYBOOK_ARGS)

images: ## List discovered Ubuntu Server ARM64 ISO images, newest first
	@./scripts/bootstrap-vm.sh --downloads "$(DOWNLOADS_DIR)" --list-images

vms: ## List registered Parallels VMs
	@"$(PRLCTL)" list --all --output uuid,name,status
