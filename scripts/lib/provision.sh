#!/usr/bin/env bash

# Run this project's Ansible playbook against one freshly installed VM without
# writing its address or workstation account into the project. Autoinstall
# grants the generated user temporary passwordless sudo; site.yml removes it.

provision_run_ansible() (
  set -euo pipefail

  local provision_project_dir="$1"
  local ansible_playbook_path="$2"
  local ssh_host="$3"
  local guest_user="$4"
  local ssh_public_key_file="$5"
  local vm_name="$6"
  local bootstrap_sudoers_path="$7"
  local developer_extra_tasks_file="$8"
  local temporary_dir
  local inventory_file
  local extra_vars_file
  local known_hosts_file
  local cleanup_playbook_file
  local ssh_identity_file
  local ssh_common_args
  local playbook_status

  temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/dev-ubuntu-provision.XXXXXX")
  inventory_file="${temporary_dir}/inventory.yml"
  extra_vars_file="${temporary_dir}/extra-vars.yml"
  known_hosts_file="${temporary_dir}/known_hosts"
  cleanup_playbook_file="${temporary_dir}/cleanup-passwordless-sudo.yml"
  ssh_identity_file=$(autoinstall_ssh_identity_file "$ssh_public_key_file")
  ssh_common_args="-oStrictHostKeyChecking=accept-new -oUserKnownHostsFile=${known_hosts_file} -oGlobalKnownHostsFile=/dev/null -oIdentitiesOnly=yes"

  # shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap.
  provision_cleanup() {
    rm -rf "$temporary_dir"
  }
  trap provision_cleanup EXIT
  touch "$known_hosts_file"
  chmod 0600 "$known_hosts_file"

  {
    printf 'all:\n'
    printf '  children:\n'
    printf '    workstation:\n'
    printf '      hosts:\n'
    printf '        bootstrap-target:\n'
    printf '          ansible_host: %s\n' \
      "$(autoinstall_json_string "$ssh_host")"
    printf '          ansible_user: %s\n' \
      "$(autoinstall_json_string "$guest_user")"
    printf '          ansible_ssh_private_key_file: %s\n' \
      "$(autoinstall_json_string "$ssh_identity_file")"
    printf '          ansible_ssh_common_args: %s\n' \
      "$(autoinstall_json_string "$ssh_common_args")"
  } >"$inventory_file"

  {
    printf 'workstation_user: %s\n' \
      "$(autoinstall_json_string "$guest_user")"
    printf 'parallels_vm_name: %s\n' \
      "$(autoinstall_json_string "$vm_name")"
    printf 'bootstrap_passwordless_sudo_path: %s\n' \
      "$(autoinstall_json_string "$bootstrap_sudoers_path")"
    printf 'install_parallels_tools_automatically: true\n'
    printf 'reboot_after_provision: true\n'
    if [[ -n "$developer_extra_tasks_file" ]]; then
      printf 'developer_extra_tasks_file: %s\n' \
        "$(autoinstall_json_string "$developer_extra_tasks_file")"
    fi
  } >"$extra_vars_file"

  {
    printf '%s\n' '---'
    printf '%s\n' '- name: Restore password-protected sudo after a failed bootstrap'
    printf '%s\n' '  hosts: workstation'
    printf '%s\n' '  gather_facts: false'
    printf '%s\n' '  become: true'
    printf '%s\n' '  tasks:'
    printf '%s\n' '    - name: Remove temporary passwordless sudo rule'
    printf '%s\n' '      ansible.builtin.file:'
    printf '        path: %s\n' \
      "$(autoinstall_json_string "$bootstrap_sudoers_path")"
    printf '%s\n' '        state: absent'
  } >"$cleanup_playbook_file"

  chmod 0600 "$inventory_file" "$extra_vars_file" "$cleanup_playbook_file"

  printf '\nSSH is ready; provisioning the workstation with Ansible...\n'
  if ANSIBLE_CONFIG="${provision_project_dir}/ansible.cfg" \
    "$ansible_playbook_path" \
      --inventory "$inventory_file" \
      "${provision_project_dir}/site.yml" \
      --extra-vars "@${extra_vars_file}"; then
    playbook_status=0
  else
    playbook_status=$?
  fi

  if ((playbook_status != 0)); then
    printf '\nProvisioning failed; removing temporary passwordless sudo...\n' >&2
    if ANSIBLE_CONFIG="${provision_project_dir}/ansible.cfg" \
      "$ansible_playbook_path" \
        --inventory "$inventory_file" \
        "$cleanup_playbook_file"; then
      printf 'Password-protected sudo was restored.\n' >&2
    else
      printf '%s\n' \
        "WARNING: cleanup could not reach the VM. Remove ${bootstrap_sudoers_path} as root before using the VM." >&2
    fi
    return "$playbook_status"
  fi

  printf '\nWorkstation provisioning completed successfully.\n'
  printf 'Connect with: ssh -i %q %q\n' \
    "$ssh_identity_file" "${guest_user}@${ssh_host}"
)

# Apply site.yml to an existing workstation with an ephemeral inventory. Unlike
# the bootstrap path, this keeps the playbook defaults for Tools installation
# and reboot behavior and forwards the caller's ansible-playbook arguments.
provision_apply_playbook() (
  set -euo pipefail

  local provision_project_dir="$1"
  local ansible_playbook_path="$2"
  local ssh_host="$3"
  local guest_user="$4"
  local ssh_public_key_file="$5"
  local vm_name="$6"
  local developer_extra_tasks_file="$7"
  shift 7

  local playbook_args=("$@")
  local temporary_dir
  local inventory_file
  local extra_vars_file
  local known_hosts_file
  local ssh_identity_file
  local ssh_common_args

  temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/dev-ubuntu-apply.XXXXXX")
  inventory_file="${temporary_dir}/inventory.yml"
  extra_vars_file="${temporary_dir}/extra-vars.yml"
  known_hosts_file="${temporary_dir}/known_hosts"
  ssh_identity_file=$(autoinstall_ssh_identity_file "$ssh_public_key_file")
  ssh_common_args="-oStrictHostKeyChecking=accept-new -oUserKnownHostsFile=${known_hosts_file} -oGlobalKnownHostsFile=/dev/null -oIdentitiesOnly=yes"

  # shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap.
  provision_apply_cleanup() {
    rm -rf "$temporary_dir"
  }
  trap provision_apply_cleanup EXIT
  touch "$known_hosts_file"
  chmod 0600 "$known_hosts_file"

  {
    printf 'all:\n'
    printf '  children:\n'
    printf '    workstation:\n'
    printf '      hosts:\n'
    printf '        apply-target:\n'
    printf '          ansible_host: %s\n' \
      "$(autoinstall_json_string "$ssh_host")"
    printf '          ansible_user: %s\n' \
      "$(autoinstall_json_string "$guest_user")"
    printf '          ansible_ssh_private_key_file: %s\n' \
      "$(autoinstall_json_string "$ssh_identity_file")"
    printf '          ansible_ssh_common_args: %s\n' \
      "$(autoinstall_json_string "$ssh_common_args")"
  } >"$inventory_file"

  {
    printf 'workstation_user: %s\n' \
      "$(autoinstall_json_string "$guest_user")"
    printf 'parallels_vm_name: %s\n' \
      "$(autoinstall_json_string "$vm_name")"
    if [[ -n "$developer_extra_tasks_file" ]]; then
      printf 'developer_extra_tasks_file: %s\n' \
        "$(autoinstall_json_string "$developer_extra_tasks_file")"
    fi
  } >"$extra_vars_file"

  chmod 0600 "$inventory_file" "$extra_vars_file"

  printf '\nApplying site.yml to %s at %s@%s...\n' \
    "$vm_name" "$guest_user" "$ssh_host"
  ANSIBLE_CONFIG="${provision_project_dir}/ansible.cfg" \
    "$ansible_playbook_path" \
      --inventory "$inventory_file" \
      "${playbook_args[@]}" \
      "${provision_project_dir}/site.yml" \
      --extra-vars "@${extra_vars_file}"
)
