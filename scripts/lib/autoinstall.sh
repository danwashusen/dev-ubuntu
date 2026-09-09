#!/usr/bin/env bash

# Helpers for producing Ubuntu Autoinstall media on macOS. The caller is
# expected to use `set -euo pipefail` and provide its own user-facing errors.

autoinstall_require_tools() {
  local tool

  for tool in \
    bsdtar hdiutil ssh ssh-keygen uuidgen xorriso \
    python3 /usr/sbin/htpasswd; do
    command -v "$tool" >/dev/null 2>&1 || {
      printf 'Missing required Autoinstall tool: %s\n' "$tool" >&2
      return 1
    }
  done

}

autoinstall_wait_for_ssh() (
  set -euo pipefail

  local ssh_host="$1"
  local guest_user="$2"
  local ssh_public_key_file="$3"
  local timeout_seconds="$4"
  local known_hosts_file
  local started_at
  local current_time
  local elapsed
  local next_report=0
  local ssh_identity_file
  local sleep_seconds

  ssh_identity_file=$(autoinstall_ssh_identity_file "$ssh_public_key_file")

  known_hosts_file=$(mktemp "${TMPDIR:-/tmp}/dev-ubuntu-known-hosts.XXXXXX")
  chmod 0600 "$known_hosts_file"
  trap 'rm -f "$known_hosts_file"' EXIT
  started_at=$(date +%s)

  printf 'Waiting up to %s seconds for SSH at %s@%s...\n' \
    "$timeout_seconds" "$guest_user" "$ssh_host"

  while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - started_at))
    if ((elapsed >= timeout_seconds)); then
      printf 'Timed out waiting for SSH at %s@%s after %s seconds.\n' \
        "$guest_user" "$ssh_host" "$elapsed" >&2
      return 1
    fi

    if ssh \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o ConnectionAttempts=1 \
      -o GlobalKnownHostsFile=/dev/null \
      -o IdentitiesOnly=yes \
      -o LogLevel=ERROR \
      -o PasswordAuthentication=no \
      -o PreferredAuthentications=publickey \
      -o StrictHostKeyChecking=accept-new \
      -o "UserKnownHostsFile=${known_hosts_file}" \
      -i "$ssh_identity_file" \
      "${guest_user}@${ssh_host}" true 2>/dev/null; then
      printf 'SSH is ready at %s@%s after %s seconds.\n' \
        "$guest_user" "$ssh_host" "$elapsed"
      return 0
    fi

    if ((elapsed >= next_report)); then
      printf '  still waiting for SSH (%ss elapsed)\n' "$elapsed"
      next_report=$((elapsed + 30))
    fi
    sleep_seconds=$((timeout_seconds - elapsed))
    if ((sleep_seconds > 5)); then
      sleep_seconds=5
    fi
    sleep "$sleep_seconds"
  done
)

autoinstall_default_ssh_key() {
  local candidate

  for candidate in \
    "${HOME}/.ssh/id_ed25519.pub" \
    "${HOME}/.ssh/id_ecdsa.pub" \
    "${HOME}/.ssh/id_rsa.pub"; do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

autoinstall_ssh_identity_file() {
  local ssh_public_key_file="$1"

  if [[ "$ssh_public_key_file" == *.pub && \
    -f "${ssh_public_key_file%.pub}" ]]; then
    printf '%s' "${ssh_public_key_file%.pub}"
  else
    printf '%s' "$ssh_public_key_file"
  fi
}

autoinstall_slug() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    tr -cs 'a-z0-9._-' '-' |
    sed -E 's/^-+//; s/-+$//'
}

autoinstall_hostname() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    tr -cs 'a-z0-9-' '-' |
    sed -E 's/^-+//; s/-+$//' |
    cut -c 1-63 |
    sed -E 's/-+$//'
}

autoinstall_read_password() {
  local output_variable="$1"
  local password
  local confirmation
  local password_bytes

  printf 'Ubuntu sudo password: ' >&2
  IFS= read -r -s password
  printf '\n' >&2
  printf 'Confirm Ubuntu sudo password: ' >&2
  IFS= read -r -s confirmation
  printf '\n' >&2

  if [[ -z "$password" ]]; then
    printf 'The Ubuntu sudo password cannot be empty.\n' >&2
    return 1
  fi
  if [[ "$password" != "$confirmation" ]]; then
    printf 'The Ubuntu sudo passwords did not match.\n' >&2
    return 1
  fi

  password_bytes=$(printf '%s' "$password" | wc -c | tr -d '[:space:]')
  if ((password_bytes > 72)); then
    printf 'The Ubuntu sudo password must be at most 72 UTF-8 bytes.\n' >&2
    return 1
  fi

  printf -v "$output_variable" '%s' "$password"
}

autoinstall_hash_password() {
  local password="$1"
  local password_hash

  password_hash=$(
    printf '%s' "$password" |
      /usr/sbin/htpasswd -niB -C 12 '' |
      sed -n '1s/^://p'
  )
  [[ "$password_hash" == \$2y\$* ]] || {
    printf 'Unable to generate a bcrypt password hash.\n' >&2
    return 1
  }
  printf '%s\n' "$password_hash"
}

autoinstall_json_string() {
  printf '%s' "$1" |
    python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

autoinstall_verify_source() {
  local installer_iso="$1"
  local source_id="$2"
  local sources

  sources=$(bsdtar -xOf "$installer_iso" casper/install-sources.yaml 2>/dev/null) || {
    printf 'Unable to read casper/install-sources.yaml from %s\n' \
      "$installer_iso" >&2
    return 1
  }

  printf '%s\n' "$sources" |
    grep -Eq "^[[:space:]]*id:[[:space:]]*${source_id}[[:space:]]*$" || {
      printf 'Ubuntu install source %s is not present in %s\n' \
        "$source_id" "$installer_iso" >&2
      return 1
    }
}

autoinstall_prepare_installer_iso() (
  set -euo pipefail

  local source_iso="$1"
  local output_iso="$2"
  local signature_file="${output_iso}.source"
  local source_signature
  local saved_signature=""
  local work_dir
  local temporary_iso

  source_signature="v2|${source_iso}|$(stat -f '%z:%m' "$source_iso")"
  if [[ -f "$output_iso" && -f "$signature_file" ]]; then
    saved_signature=$(<"$signature_file")
    if [[ "$saved_signature" == "$source_signature" ]]; then
      printf 'Reusing cached unattended installer: %s\n' "$output_iso"
      exit 0
    fi
  fi

  mkdir -p "$(dirname "$output_iso")"
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dev-ubuntu-installer.XXXXXX")
  temporary_iso="${output_iso}.tmp.$$.iso"

  trap 'rm -rf "$work_dir"; rm -f "$temporary_iso"' EXIT

  bsdtar -xOf "$source_iso" boot/grub/grub.cfg >"${work_dir}/grub.cfg.original"
  awk '
    /^[[:space:]]*set timeout=/ {
      print "set timeout=5"
      next
    }
    /^[[:space:]]*linux[[:space:]]+\/casper\/vmlinuz/ {
      if ($0 !~ /(^|[[:space:]])autoinstall([[:space:]]|$)/) {
        sub(/[[:space:]]+---[[:space:]]+/, " autoinstall --- ")
      }
    }
    { print }
  ' "${work_dir}/grub.cfg.original" >"${work_dir}/grub.cfg"

  grep -Eq 'linux[[:space:]]+/casper/vmlinuz.*[[:space:]]autoinstall[[:space:]]+---' \
    "${work_dir}/grub.cfg" || {
      printf 'Unable to add the autoinstall kernel argument to %s\n' \
        "$source_iso" >&2
      exit 1
    }

  printf 'Building unattended installer image (cached after this run)...\n'
  xorriso \
    -indev "$source_iso" \
    -outdev "$temporary_iso" \
    -boot_image any replay \
    -map "${work_dir}/grub.cfg" /boot/grub/grub.cfg

  mv -f "$temporary_iso" "$output_iso"
  chmod 0644 "$output_iso"
  printf '%s\n' "$source_signature" >"$signature_file"
  chmod 0644 "$signature_file"
)

autoinstall_build_seed_iso() (
  set -euo pipefail

  local output_iso="$1"
  local guest_user="$2"
  local guest_hostname="$3"
  local password_hash="$4"
  local ssh_public_key_file="$5"
  local timezone="$6"
  local locale="$7"
  local keyboard_layout="$8"
  local source_id="$9"
  local bootstrap_sudoers_path="${10}"
  local work_dir
  local temporary_iso
  local ssh_public_key
  local instance_id
  local guest_user_yaml
  local guest_hostname_yaml
  local password_hash_yaml
  local ssh_public_key_yaml
  local timezone_yaml
  local locale_yaml
  local keyboard_layout_yaml
  local source_id_yaml
  local bootstrap_sudoers_command
  local bootstrap_sudoers_command_yaml
  local instance_id_yaml

  mkdir -p "$(dirname "$output_iso")"
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dev-ubuntu-seed.XXXXXX")
  temporary_iso="${output_iso}.tmp.$$.iso"

  trap 'rm -rf "$work_dir"; rm -f "$temporary_iso"' EXIT

  ssh_public_key=$(tr -d '\r\n' <"$ssh_public_key_file")
  instance_id="iid-$(uuidgen | tr '[:upper:]' '[:lower:]')"

  guest_user_yaml=$(autoinstall_json_string "$guest_user")
  guest_hostname_yaml=$(autoinstall_json_string "$guest_hostname")
  password_hash_yaml=$(autoinstall_json_string "$password_hash")
  ssh_public_key_yaml=$(autoinstall_json_string "$ssh_public_key")
  timezone_yaml=$(autoinstall_json_string "$timezone")
  locale_yaml=$(autoinstall_json_string "$locale")
  keyboard_layout_yaml=$(autoinstall_json_string "$keyboard_layout")
  source_id_yaml=$(autoinstall_json_string "$source_id")
  bootstrap_sudoers_command="curtin in-target --target=/target -- /bin/sh -c 'printf \"%s\\n\" \"${guest_user} ALL=(ALL:ALL) NOPASSWD: ALL\" > ${bootstrap_sudoers_path} && chmod 0440 ${bootstrap_sudoers_path} && /usr/sbin/visudo -cf ${bootstrap_sudoers_path}'"
  bootstrap_sudoers_command_yaml=$(
    autoinstall_json_string "$bootstrap_sudoers_command"
  )
  instance_id_yaml=$(autoinstall_json_string "$instance_id")

  {
    printf '#cloud-config\n'
    printf 'autoinstall:\n'
    printf '  version: 1\n'
    printf '  refresh-installer:\n'
    printf '    update: false\n'
    printf '  source:\n'
    printf '    id: %s\n' "$source_id_yaml"
    printf '  locale: %s\n' "$locale_yaml"
    printf '  keyboard:\n'
    printf '    layout: %s\n' "$keyboard_layout_yaml"
    printf '  timezone: %s\n' "$timezone_yaml"
    printf '  identity:\n'
    printf '    hostname: %s\n' "$guest_hostname_yaml"
    printf '    username: %s\n' "$guest_user_yaml"
    printf '    password: %s\n' "$password_hash_yaml"
    printf '  ssh:\n'
    printf '    install-server: true\n'
    printf '    allow-pw: false\n'
    printf '    authorized-keys:\n'
    printf '      - %s\n' "$ssh_public_key_yaml"
    printf '  storage:\n'
    printf '    layout:\n'
    printf '      name: direct\n'
    printf '  packages:\n'
    printf '    - avahi-daemon\n'
    printf '    - python3\n'
    printf '  updates: security\n'
    printf '  late-commands:\n'
    printf '    - %s\n' "$bootstrap_sudoers_command_yaml"
    printf '  shutdown: reboot\n'
  } >"${work_dir}/user-data"

  {
    printf 'instance-id: %s\n' "$instance_id_yaml"
    printf 'local-hostname: %s\n' "$guest_hostname_yaml"
  } >"${work_dir}/meta-data"

  chmod 0600 "${work_dir}/user-data" "${work_dir}/meta-data"

  if command -v yq >/dev/null 2>&1; then
    yq eval '.' "${work_dir}/user-data" >/dev/null
    yq eval '.' "${work_dir}/meta-data" >/dev/null
  fi

  hdiutil makehybrid \
    -iso \
    -joliet \
    -iso-volume-name CIDATA \
    -joliet-volume-name CIDATA \
    -o "$temporary_iso" \
    "$work_dir" >/dev/null

  mv -f "$temporary_iso" "$output_iso"
  chmod 0600 "$output_iso"
)
