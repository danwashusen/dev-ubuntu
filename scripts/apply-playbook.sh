#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib/autoinstall.sh
source "${script_dir}/lib/autoinstall.sh"
# shellcheck source=scripts/lib/provision.sh
source "${script_dir}/lib/provision.sh"

prlctl_path="/usr/local/bin/prlctl"
vm_name=""
guest_user=""
ssh_host=""
ssh_public_key_file=""
ssh_wait_timeout=2700
ansible_playbook_path=""
developer_extra_tasks_file=""
playbook_args=()

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: apply-playbook.sh [options] -- [ansible-playbook options]

Options:
  --prlctl PATH       Path to prlctl
  --name NAME         Existing Parallels VM name (required)
  --guest-user NAME   Ubuntu user (default: current macOS user)
  --ssh-host HOST     SSH host (default: Parallels IPv4 or VM-name.local)
  --ssh-key PATH      Authorized SSH public key
  --ssh-timeout SEC   Maximum SSH wait in seconds (default: 2700)
  --ansible PATH      Path to ansible-playbook
  --developer-extra-tasks PATH
                      Optional developer task file, relative to the project or absolute
  --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prlctl)
      prlctl_path="$2"
      shift 2
      ;;
    --name)
      vm_name="$2"
      shift 2
      ;;
    --guest-user)
      guest_user="$2"
      shift 2
      ;;
    --ssh-host)
      ssh_host="$2"
      shift 2
      ;;
    --ssh-key)
      ssh_public_key_file="$2"
      shift 2
      ;;
    --ssh-timeout)
      ssh_wait_timeout="$2"
      shift 2
      ;;
    --ansible)
      ansible_playbook_path="$2"
      shift 2
      ;;
    --developer-extra-tasks)
      developer_extra_tasks_file="$2"
      shift 2
      ;;
    --)
      shift
      playbook_args=("$@")
      break
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if [[ -n "$developer_extra_tasks_file" ]]; then
  if [[ "$developer_extra_tasks_file" != /* ]]; then
    developer_extra_tasks_file="${project_dir}/${developer_extra_tasks_file}"
  fi
  [[ -f "$developer_extra_tasks_file" ]] ||
    die "Developer task file does not exist: $developer_extra_tasks_file"
fi

[[ -n "$vm_name" ]] || die "VM_NAME is required"
[[ -x "$prlctl_path" ]] || die "prlctl is not executable at $prlctl_path"
[[ "$ssh_wait_timeout" =~ ^[1-9][0-9]*$ ]] ||
  die "SSH wait timeout must be a positive integer"

if ! "$prlctl_path" list --all --output name --no-header |
  grep -Fqx -- "$vm_name"; then
  die "Parallels VM does not exist: $vm_name"
fi

vm_status=$(
  "$prlctl_path" list --output status --no-header "$vm_name" |
    awk '{$1=$1; print}'
)
if [[ "$vm_status" != "running" ]]; then
  printf 'Starting Parallels VM: %s\n' "$vm_name"
  "$prlctl_path" start "$vm_name"
fi

[[ -n "$guest_user" ]] || guest_user=$(id -un)
if [[ -z "$ssh_public_key_file" ]]; then
  ssh_public_key_file=$(autoinstall_default_ssh_key || true)
fi
[[ -n "$ssh_public_key_file" && -f "$ssh_public_key_file" ]] ||
  die "Set SSH_PUBLIC_KEY to the public key authorized by the VM"
ssh_identity_file=$(autoinstall_ssh_identity_file "$ssh_public_key_file")
[[ -f "$ssh_identity_file" ]] ||
  die "A matching private SSH key is required: $ssh_identity_file"

if [[ -z "$ansible_playbook_path" ]]; then
  ansible_playbook_path=$(command -v ansible-playbook || true)
fi
[[ -n "$ansible_playbook_path" && -x "$ansible_playbook_path" ]] ||
  die "ansible-playbook is required"

if [[ -z "$ssh_host" ]]; then
  ssh_host=$(
    "$prlctl_path" list --full --output ip --no-header "$vm_name" 2>/dev/null |
      awk '{
        for (field = 1; field <= NF; field++) {
          if ($field ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
              $field !~ /^127\./) {
            print $field
            exit
          }
        }
      }'
  )
fi
if [[ -z "$ssh_host" ]]; then
  ssh_host="$(autoinstall_hostname "$vm_name").local"
fi

autoinstall_wait_for_ssh \
  "$ssh_host" \
  "$guest_user" \
  "$ssh_public_key_file" \
  "$ssh_wait_timeout" ||
  die "The VM is running, but SSH did not become ready"

provision_apply_playbook \
  "$project_dir" \
  "$ansible_playbook_path" \
  "$ssh_host" \
  "$guest_user" \
  "$ssh_public_key_file" \
  "$vm_name" \
  "$developer_extra_tasks_file" \
  "${playbook_args[@]}"
