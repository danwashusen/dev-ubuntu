#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib/autoinstall.sh
source "${script_dir}/lib/autoinstall.sh"
# shellcheck source=scripts/lib/provision.sh
source "${script_dir}/lib/provision.sh"

prlctl_path="/usr/local/bin/prlctl"
downloads_dir=""
sizing_vm=""
vm_name=""
image_path=""
cpu_count=""
memory_mb=""
disk_gb=""
start_vm=""
resume_vm="no"
autoinstall_enabled="yes"
guest_user=""
guest_hostname=""
ssh_public_key_file=""
artifacts_dir=""
autoinstall_timezone="Australia/Melbourne"
autoinstall_locale="en_AU.UTF-8"
autoinstall_keyboard_layout="us"
autoinstall_source_id="ubuntu-server"
bootstrap_sudoers_path="/etc/sudoers.d/99-dev-ubuntu-bootstrap"
wait_for_ssh="yes"
ssh_host=""
ssh_wait_timeout=2700
run_ansible="yes"
ansible_playbook_path=""
list_images_only=false

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

usage() {
  cat <<'EOF'
Usage: bootstrap-vm.sh [options]

Options:
  --prlctl PATH       Path to prlctl
  --downloads PATH    Directory searched recursively for Ubuntu Server ISOs
  --sizing-vm NAME    Existing VM used to override CPU, memory, and disk defaults
  --name NAME         New VM name
  --image PATH        Ubuntu Server ARM64 ISO
  --cpus COUNT        Virtual CPU count
  --memory-mb MB      VM memory in megabytes
  --disk-gb GB        Virtual disk size in gigabytes
  --start YES_OR_NO   Start the VM after creation
  --resume YES_OR_NO  Continue configuring an existing interrupted build
  --autoinstall BOOL  Enable Ubuntu Autoinstall (default: yes)
  --guest-user NAME   Ubuntu user (default: current macOS user)
  --hostname NAME     Ubuntu hostname (default: normalized VM name)
  --ssh-key PATH      One SSH public key to authorize
  --artifacts PATH    Generated-media directory
  --wait-for-ssh BOOL Wait for key-based SSH (default: yes)
  --ssh-host HOST     SSH host (default: generated hostname.local)
  --ssh-timeout SEC   Maximum SSH wait in seconds (default: 2700)
  --run-ansible BOOL  Provision and reboot after SSH is ready (default: yes)
  --ansible PATH      Path to ansible-playbook
  --list-images       List discovered images and exit
  --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prlctl)
      prlctl_path="$2"
      shift 2
      ;;
    --downloads)
      downloads_dir="$2"
      shift 2
      ;;
    --sizing-vm | --source)
      sizing_vm="$2"
      shift 2
      ;;
    --name)
      vm_name="$2"
      shift 2
      ;;
    --image)
      image_path="$2"
      shift 2
      ;;
    --cpus)
      cpu_count="$2"
      shift 2
      ;;
    --memory-mb)
      memory_mb="$2"
      shift 2
      ;;
    --disk-gb)
      disk_gb="$2"
      shift 2
      ;;
    --start)
      start_vm="$2"
      shift 2
      ;;
    --resume)
      resume_vm="$2"
      shift 2
      ;;
    --autoinstall)
      autoinstall_enabled="$2"
      shift 2
      ;;
    --guest-user)
      guest_user="$2"
      shift 2
      ;;
    --hostname)
      guest_hostname="$2"
      shift 2
      ;;
    --ssh-key)
      ssh_public_key_file="$2"
      shift 2
      ;;
    --artifacts)
      artifacts_dir="$2"
      shift 2
      ;;
    --wait-for-ssh)
      wait_for_ssh="$2"
      shift 2
      ;;
    --ssh-host)
      ssh_host="$2"
      shift 2
      ;;
    --ssh-timeout)
      ssh_wait_timeout="$2"
      shift 2
      ;;
    --run-ansible)
      run_ansible="$2"
      shift 2
      ;;
    --ansible)
      ansible_playbook_path="$2"
      shift 2
      ;;
    --list-images)
      list_images_only=true
      shift
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

if [[ -z "$downloads_dir" ]]; then
  downloads_dir="${HOME}/Downloads"
fi
if [[ -z "$artifacts_dir" ]]; then
  artifacts_dir="${project_dir}/.artifacts/autoinstall"
fi

list_image_records() {
  local candidate
  local modified

  [[ -d "$downloads_dir" ]] || return 0

  while IFS= read -r -d '' candidate; do
    modified=$(stat -f '%m' "$candidate")
    printf '%s\t%s\n' "$modified" "$candidate"
  done < <(
    find "$downloads_dir" -type f \
      \( -iname '*ubuntu*server*arm64*.iso' \
      -o -iname '*ubuntu*live-server*arm64*.iso' \) \
      -print0
  )
}

show_images() {
  local modified
  local candidate
  local formatted

  while IFS=$'\t' read -r modified candidate; do
    [[ -n "$candidate" ]] || continue
    formatted=$(date -r "$modified" '+%Y-%m-%d %H:%M:%S')
    printf '%s  %s\n' "$formatted" "$candidate"
  done < <(list_image_records | sort -rn)
}

if [[ "$list_images_only" == true ]]; then
  show_images
  exit 0
fi

[[ -x "$prlctl_path" ]] || die "prlctl is not executable at $prlctl_path"

prompt_value() {
  local label="$1"
  local default_value="$2"
  local answer=""

  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value]: " answer || true
    printf '%s' "${answer:-$default_value}"
  else
    read -r -p "$label: " answer || true
    printf '%s' "$answer"
  fi
}

vm_exists() {
  "$prlctl_path" list --all --output name --no-header | grep -Fqx -- "$1"
}

# These values and the integration settings applied below form the checked-in
# "Dev Server" profile. A live source VM is deliberately not required.
default_cpus=4
default_memory_mb=8192
default_disk_gb=24

if [[ -n "$sizing_vm" ]]; then
  vm_exists "$sizing_vm" || die "Sizing VM does not exist: $sizing_vm"
  source_info=$("$prlctl_path" list --info "$sizing_vm")

  source_cpus=$(
    printf '%s\n' "$source_info" |
      sed -nE 's/^[[:space:]]*cpu cpus=([0-9]+).*/\1/p' |
      head -n 1
  )
  source_memory_mb=$(
    printf '%s\n' "$source_info" |
      sed -nE 's/^[[:space:]]*memory size=([0-9]+)Mb.*/\1/p' |
      head -n 1
  )
  source_disk_mb=$(
    printf '%s\n' "$source_info" |
      sed -nE 's/^[[:space:]]*hdd0 .* ([0-9]+)Mb .*/\1/p' |
      head -n 1
  )

  [[ -n "$source_cpus" ]] && default_cpus="$source_cpus"
  [[ -n "$source_memory_mb" ]] && default_memory_mb="$source_memory_mb"
  if [[ -n "$source_disk_mb" ]]; then
    default_disk_gb=$(((source_disk_mb + 1023) / 1024))
  fi
fi

if [[ -z "$vm_name" ]]; then
  default_name="Dev Ubuntu"
  name_number=2
  while vm_exists "$default_name"; do
    default_name="Dev Ubuntu ${name_number}"
    name_number=$((name_number + 1))
  done
  vm_name=$(prompt_value "New VM name" "$default_name")
fi

resume_vm_lower=$(lowercase "$resume_vm")
case "$resume_vm_lower" in
  y | yes | true | 1)
    resume_vm=yes
    ;;
  n | no | false | 0)
    resume_vm=no
    ;;
  *)
    die "Resume VM must be yes or no"
    ;;
esac

autoinstall_enabled_lower=$(lowercase "$autoinstall_enabled")
case "$autoinstall_enabled_lower" in
  y | yes | true | 1)
    autoinstall_enabled=yes
    ;;
  n | no | false | 0)
    autoinstall_enabled=no
    ;;
  *)
    die "Autoinstall must be yes or no"
    ;;
esac

wait_for_ssh_lower=$(lowercase "$wait_for_ssh")
case "$wait_for_ssh_lower" in
  y | yes | true | 1)
    wait_for_ssh=yes
    ;;
  n | no | false | 0)
    wait_for_ssh=no
    ;;
  *)
    die "Wait for SSH must be yes or no"
    ;;
esac

run_ansible_lower=$(lowercase "$run_ansible")
case "$run_ansible_lower" in
  y | yes | true | 1)
    run_ansible=yes
    ;;
  n | no | false | 0)
    run_ansible=no
    ;;
  *)
    die "Run Ansible must be yes or no"
    ;;
esac

if [[ "$run_ansible" == yes ]]; then
  [[ "$autoinstall_enabled" == yes ]] ||
    die "Automatic Ansible provisioning requires AUTOINSTALL=yes"
  [[ "$wait_for_ssh" == yes ]] ||
    die "Automatic Ansible provisioning requires WAIT_FOR_SSH=yes"
  if [[ -z "$ansible_playbook_path" ]]; then
    ansible_playbook_path=$(command -v ansible-playbook || true)
  fi
  [[ -n "$ansible_playbook_path" && -x "$ansible_playbook_path" ]] ||
    die "ansible-playbook is required when RUN_ANSIBLE=yes"
fi

[[ "$ssh_wait_timeout" =~ ^[1-9][0-9]*$ ]] ||
  die "SSH wait timeout must be a positive integer"

vm_already_exists=false
if vm_exists "$vm_name"; then
  if [[ "$resume_vm" == yes ]]; then
    vm_already_exists=true
  else
    die "A VM named '$vm_name' already exists; set RESUME=yes only for an interrupted bootstrap"
  fi
fi

if [[ -z "$image_path" ]]; then
  latest_record=$(list_image_records | sort -rn | head -n 1 || true)
  latest_image="${latest_record#*$'\t'}"
  [[ "$latest_image" != "$latest_record" ]] || latest_image=""
  image_path=$(prompt_value "Ubuntu Server ARM64 ISO" "$latest_image")
fi

autoinstall_installer_iso=""
autoinstall_seed_iso=""
if [[ "$autoinstall_enabled" == yes ]]; then
  autoinstall_require_tools ||
    die "Install xorriso with 'brew install xorriso' and ensure Python 3 is available"

  [[ -n "$guest_user" ]] || guest_user=$(prompt_value "Ubuntu user" "$(id -un)")
  [[ -n "$guest_hostname" ]] ||
    guest_hostname=$(prompt_value "Ubuntu hostname" "$(autoinstall_hostname "$vm_name")")
  if [[ -z "$ssh_public_key_file" ]]; then
    default_ssh_public_key=$(autoinstall_default_ssh_key || true)
    ssh_public_key_file=$(prompt_value "SSH public key" "$default_ssh_public_key")
  fi

  [[ "$guest_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
    die "Ubuntu user must be a valid lowercase Linux account name"
  [[ "$guest_hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    die "Ubuntu hostname must be a valid lowercase hostname of at most 63 characters"
  [[ -f "$ssh_public_key_file" ]] ||
    die "SSH public key does not exist: $ssh_public_key_file"
  ssh-keygen -lf "$ssh_public_key_file" >/dev/null 2>&1 ||
    die "SSH public key is invalid: $ssh_public_key_file"
  ssh_identity_file=$(autoinstall_ssh_identity_file "$ssh_public_key_file")
  [[ "$ssh_identity_file" != "$ssh_public_key_file" && \
    -f "$ssh_identity_file" ]] ||
    die "A matching private key is required for SSH: ${ssh_public_key_file%.pub}"
  autoinstall_verify_source "$image_path" "$autoinstall_source_id" ||
    die "The selected ISO is not compatible with the Ubuntu Server Autoinstall profile"

  artifact_slug=$(autoinstall_slug "$vm_name")
  image_basename=$(basename "$image_path")
  autoinstall_installer_iso="${artifacts_dir}/installer/${image_basename%.iso}-autoinstall.iso"
  autoinstall_seed_iso="${artifacts_dir}/${artifact_slug}-cidata.iso"
  [[ -n "$ssh_host" ]] || ssh_host="${guest_hostname}.local"
fi

[[ -n "$cpu_count" ]] || cpu_count=$(prompt_value "Virtual CPUs" "$default_cpus")
[[ -n "$memory_mb" ]] || memory_mb=$(prompt_value "Memory in MB" "$default_memory_mb")
[[ -n "$disk_gb" ]] || disk_gb=$(prompt_value "Disk size in GB" "$default_disk_gb")
[[ -n "$start_vm" ]] || start_vm=$(prompt_value "Start VM after creation (yes/no)" "yes")

[[ -n "$vm_name" ]] || die "VM name cannot be empty"
[[ -f "$image_path" ]] || die "ISO image does not exist: $image_path"
image_path_lower=$(lowercase "$image_path")
[[ "$image_path_lower" == *ubuntu*server*arm64*.iso ]] ||
  die "Expected an Ubuntu Server ARM64 ISO: $image_path"
[[ "$cpu_count" =~ ^[1-9][0-9]*$ ]] || die "CPU count must be a positive integer"
[[ "$memory_mb" =~ ^[1-9][0-9]*$ ]] || die "Memory must be a positive integer"
[[ "$disk_gb" =~ ^[1-9][0-9]*$ ]] || die "Disk size must be a positive integer"
((disk_gb >= 16)) || die "Disk size must be at least 16 GB"

start_vm_lower=$(lowercase "$start_vm")
case "$start_vm_lower" in
  y | yes | true | 1)
    start_vm=yes
    ;;
  n | no | false | 0)
    start_vm=no
    ;;
  *)
    die "Start VM must be yes or no"
    ;;
esac

if [[ "$run_ansible" == yes && "$start_vm" != yes ]]; then
  die "Automatic Ansible provisioning requires START_VM=yes"
fi

printf '\nProposed Parallels VM\n'
if [[ "$vm_already_exists" == true ]]; then
  printf '  Action:          resume interrupted configuration\n'
else
  printf '  Action:          create new VM\n'
fi
printf '  Config profile:  Dev Server (built in)\n'
if [[ -n "$sizing_vm" ]]; then
  printf '  Sizing override: %s\n' "$sizing_vm"
fi
printf '  Name:            %s\n' "$vm_name"
printf '  Image:           %s\n' "$image_path"
printf '  Architecture:    ARM64 / EFI\n'
printf '  CPUs:            %s\n' "$cpu_count"
printf '  Memory:          %s MB\n' "$memory_mb"
printf '  Disk:            %s GB (expanding)\n' "$disk_gb"
printf '  Network:         shared\n'
printf '  Clipboard:       bidirectional\n'
printf '  Time sync:       enabled, UTC only\n'
printf '  Integration:     apps, folders, profile, cloud, printers, cameras,\n'
printf '                   smart cards, gamepads, location and SSH injection off\n'
if [[ "$autoinstall_enabled" == yes ]]; then
  printf '  Autoinstall:     enabled (entire VM disk)\n'
  printf '  Ubuntu source:   standard server\n'
  printf '  Ubuntu user:     %s\n' "$guest_user"
  printf '  Ubuntu hostname: %s\n' "$guest_hostname"
  printf '  SSH public key:  %s\n' "$ssh_public_key_file"
  printf '  CIDATA image:    %s\n' "$autoinstall_seed_iso"
  if [[ "$wait_for_ssh" == yes && "$start_vm" == yes ]]; then
    printf '  Wait for SSH:    %s@%s (%ss timeout)\n' \
      "$guest_user" "$ssh_host" "$ssh_wait_timeout"
  else
    printf '  Wait for SSH:    disabled\n'
  fi
  if [[ "$run_ansible" == yes ]]; then
    printf '  Provisioning:    full Ansible playbook, Parallels Tools, reboot\n'
  else
    printf '  Provisioning:    disabled\n'
  fi
else
  printf '  Autoinstall:     disabled (interactive installer)\n'
fi
printf '  Start afterward: %s\n\n' "$start_vm"

confirmation=""
if [[ "$vm_already_exists" == true ]]; then
  confirmation_prompt="Resume configuration of this VM? [y/N]: "
else
  confirmation_prompt="Create this VM? [y/N]: "
fi
read -r -p "$confirmation_prompt" confirmation || true
confirmation_lower=$(lowercase "$confirmation")
case "$confirmation_lower" in
  y | yes)
    ;;
  *)
    printf 'Cancelled; no VM was created.\n'
    exit 0
    ;;
esac

disk_mb=$((disk_gb * 1024))
boot_image_path="$image_path"

if [[ "$autoinstall_enabled" == yes ]]; then
  autoinstall_plaintext_password=""
  autoinstall_read_password autoinstall_plaintext_password ||
    die "Unable to read the Ubuntu sudo password"
  password_hash=$(autoinstall_hash_password "$autoinstall_plaintext_password") ||
    die "Unable to create the Ubuntu sudo password hash"
  autoinstall_prepare_installer_iso "$image_path" "$autoinstall_installer_iso"
  autoinstall_build_seed_iso \
    "$autoinstall_seed_iso" \
    "$guest_user" \
    "$guest_hostname" \
    "$password_hash" \
    "$ssh_public_key_file" \
    "$autoinstall_timezone" \
    "$autoinstall_locale" \
    "$autoinstall_keyboard_layout" \
    "$autoinstall_source_id" \
    "$bootstrap_sudoers_path"
  unset password_hash autoinstall_plaintext_password
  boot_image_path="$autoinstall_installer_iso"
fi

if [[ "$vm_already_exists" == false ]]; then
  "$prlctl_path" create "$vm_name" --distribution ubuntu
fi
"$prlctl_path" set "$vm_name" \
  --cpus "$cpu_count" \
  --memsize "$memory_mb"

current_disk_mb=$(
  "$prlctl_path" list --info "$vm_name" |
    sed -nE 's/^[[:space:]]*hdd0 .* ([0-9]+)Mb .*/\1/p' |
    head -n 1
)
if [[ -z "$current_disk_mb" || "$current_disk_mb" -le "$disk_mb" ]]; then
  "$prlctl_path" set "$vm_name" \
    --device-set hdd0 \
    --size "$disk_mb" \
    --type expand \
    --online-compact on
else
  printf 'Keeping existing %s MB disk; refusing to shrink it to %s MB.\n' \
    "$current_disk_mb" "$disk_mb"
fi
"$prlctl_path" set "$vm_name" \
  --bios-type efi-arm64 \
  --efi-secure-boot off \
  --device-bootorder "hdd0 cdrom0"
"$prlctl_path" set "$vm_name" \
  --video-adapter-type virtio \
  --videosize auto \
  --3d-accelerate highest \
  --vertical-sync on \
  --high-resolution off \
  --high-resolution-in-guest on \
  --native-scaling-in-guest off
"$prlctl_path" set "$vm_name" \
  --faster-vm on \
  --hypervisor-type apple \
  --nested-virt off \
  --longer-battery-life off \
  --smart-mouse-optimize auto \
  --support-usb30 on
"$prlctl_path" set "$vm_name" \
  --sync-host-printers off \
  --sync-default-printer off \
  --show-host-printer-ui off \
  --auto-share-camera off \
  --auto-share-smart-card off
"$prlctl_path" set "$vm_name" \
  --auto-share-gamepad off
"$prlctl_path" set "$vm_name" \
  --shf-host off \
  --shf-host-defined off \
  --shf-host-automount off \
  --shf-guest off \
  --shared-profile off \
  --sh-app-host-to-guest off \
  --sh-app-guest-to-host off \
  --show-guest-app-folder-in-dock off \
  --bounce-dock-icon-when-app-flashes off
"$prlctl_path" set "$vm_name" \
  --smart-mount off \
  --smart-mount-removable-drives off \
  --smart-mount-dvd-drives off \
  --smart-mount-network-shares off \
  --shared-clipboard on \
  --shared-cloud off
"$prlctl_path" set "$vm_name" \
  --sync-vm-hostname off \
  --sync-ssh-ids off \
  --show-dev-tools off \
  --share-host-location off \
  --rosetta-linux off \
  --tools-autoupdate yes
"$prlctl_path" set "$vm_name" \
  --time-sync on \
  --time-sync-smart-mode off \
  --disable-timezone-sync on \
  --time-sync-interval 60
"$prlctl_path" set "$vm_name" \
  --autostart off \
  --autostop suspend \
  --startup-view window \
  --on-window-close suspend
"$prlctl_path" set "$vm_name" \
  --device-set cdrom0 \
  --image "$boot_image_path" \
  --connect

if [[ "$autoinstall_enabled" == yes ]]; then
  if "$prlctl_path" list --info "$vm_name" |
    grep -Eq '^[[:space:]]*cdrom1[[:space:]]'; then
    "$prlctl_path" set "$vm_name" \
      --device-set cdrom1 \
      --image "$autoinstall_seed_iso"
  else
    "$prlctl_path" set "$vm_name" \
      --device-add cdrom \
      --image "$autoinstall_seed_iso" \
      --iface sata
  fi
  "$prlctl_path" set "$vm_name" \
    --device-set cdrom1 \
    --connect
fi

printf '\nConfigured VM: %s\n' "$vm_name"
if [[ "$autoinstall_enabled" == yes ]]; then
  printf 'Ubuntu will install unattended and should become reachable at %s.local.\n' \
    "$guest_hostname"
  printf 'The private CIDATA image remains at: %s\n' "$autoinstall_seed_iso"
fi

if [[ "$start_vm" == yes ]]; then
  "$prlctl_path" start "$vm_name"
  if [[ "$autoinstall_enabled" == yes && "$wait_for_ssh" == yes ]]; then
    autoinstall_wait_for_ssh \
      "$ssh_host" \
      "$guest_user" \
      "$ssh_public_key_file" \
      "$ssh_wait_timeout" ||
      die "The VM is still running; inspect its console or retry SSH manually"

    if [[ "$run_ansible" == yes ]]; then
      provision_run_ansible \
        "$project_dir" \
        "$ansible_playbook_path" \
        "$ssh_host" \
        "$guest_user" \
        "$ssh_public_key_file" \
        "$vm_name" \
        "$bootstrap_sudoers_path"
    fi
  fi
else
  printf 'Start it later with: %q start %q\n' "$prlctl_path" "$vm_name"
fi

unset autoinstall_plaintext_password 2>/dev/null || true
