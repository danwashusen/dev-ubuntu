# Ubuntu ARM64 developer workstation

An Ansible project for turning a fresh **Ubuntu Server 26.04.1 LTS ARM64**
guest in Parallels Desktop into a lean, keyboard-first developer workstation.
It installs Hyprland without a conventional desktop environment, keeps Ubuntu's
netplan/systemd-networkd networking, and uses lightweight desktop components.

## What it installs

- Base OS tools and Parallels Tools build prerequisites
- zsh, Starship, Neovim, tmux, lazygit, GitHub CLI, and modern CLI utilities
- Firefox from Mozilla's DEB repository (not Snap)
- Google Chrome for Linux ARM64, Visual Studio Code ARM64, mise, and Claude Code
- Docker Engine, Buildx, and Compose from Docker's repository
- Hyprland, greetd/agreety, Ghostty, Waybar, fuzzel, mako, Nautilus, PipeWire,
  portals, clipboard history, locking, and screenshot tools
- Ubuntu's JetBrains Mono package, applied to Ghostty, Waybar, fuzzel, mako,
  and GTK 3/4 applications

The project intentionally does **not** install GNOME/KDE, `ubuntu-desktop`,
GDM/SDDM, NetworkManager, a dock, or desktop icons.

## Prerequisites

For an automated VM build, install Parallels Desktop Pro or Business, Ansible,
Python 3, and `xorriso` on the Mac, and have an SSH public key available. For
example:

```bash
brew install ansible python xorriso
```

For a VM installed separately, create a normal user with sudo access, enable
SSH during installation, and make sure the Mac can reach it over SSH.

Only modules included with `ansible-core` are used; no Galaxy collections are
required.

Ubuntu 26.04 uses `sudo-rs` by default. Older Ansible controllers do not
recognise its authentication prompt, so this project sets Ansible's privilege
escalation executable to Ubuntu's supported `/usr/bin/sudo.ws` compatibility
implementation. This affects Ansible only; interactive `sudo` remains
`sudo-rs`.

## Bootstrap a Parallels VM

The Make workflow creates the VM hardware and, by default, performs an Ubuntu
Autoinstall before Ansible takes over. Run:

```bash
make bootstrap
```

The workflow uses a checked-in **Dev Server** configuration profile as its
default. This is a baked-in set of sizing and lean integration settings; it
does not clone, inspect, or otherwise depend on a VM named `Dev Server` being
registered. It recursively searches `~/Downloads` for Ubuntu Server ARM64 ISOs
and offers the most recently modified image. Before changing anything, it
prompts for the VM name, ISO, CPUs, memory, disk size, and whether to start,
displays the complete proposal, and requires explicit confirmation.

The created VM uses a lean Linux integration profile: bidirectional clipboard
and UTC time synchronization are enabled; application sharing, shared folders,
shared profile/cloud, printer synchronization, automatic camera/smart-card/
gamepad sharing, host location, Rosetta, and automatic SSH-key injection are
disabled.

Autoinstall defaults the Ubuntu username to the current macOS account name and
the hostname to a normalized form of the VM name. It selects one SSH public key
(preferring `~/.ssh/id_ed25519.pub`), prompts twice for a local/sudo password,
installs standard Ubuntu Server onto the entire virtual disk, disables SSH
password authentication, and reboots. The normal Linux numeric UID is retained;
only the account name is matched to the Mac.

The local/sudo password is hashed with bcrypt before it is written to CIDATA,
then the plaintext is discarded. Autoinstall creates a temporary, user-scoped
`NOPASSWD` sudoers rule so Ansible can run unattended. After the final reboot,
the playbook removes that rule as its last privileged action, restoring normal
password-protected sudo. If provisioning fails, the controller makes a separate
best-effort cleanup attempt and warns prominently if the VM cannot be reached.

The workflow creates two ignored artifacts under `.artifacts/autoinstall`: a
cached copy of the Ubuntu ISO whose GRUB entry includes the `autoinstall` kernel
argument, and a per-VM CIDATA ISO. The latter contains the password hash and SSH
public key, is mode `0600`, and must never be committed or shared. The existing
host-side confirmation remains the destructive safety boundary before the
installer is allowed to replace the VM disk.

List discovered images or registered VMs with:

```bash
make images
make vms
```

Any prompt default can be supplied up front while retaining the final safety
confirmation:

```bash
make bootstrap \
  VM_NAME="Ubuntu Workstation" \
  IMAGE="$HOME/Downloads/ubuntu-26.04.1-live-server-arm64.iso" \
  CPUS=8 MEMORY_MB=8192 DISK_GB=24 START_VM=yes
```

Override the generated identity or selected public key when needed:

```bash
make bootstrap \
  GUEST_USER="developer" \
  GUEST_HOSTNAME="ubuntu-workstation" \
  SSH_PUBLIC_KEY="$HOME/.ssh/id_ed25519.pub"
```

Set `AUTOINSTALL=no RUN_ANSIBLE=no` to retain the original interactive Ubuntu
installer.

To take only the CPU, memory, and disk defaults from a currently registered VM,
set `SIZING_VM="VM name"`. The Dev Server integration profile remains in force.

If Parallels fails after creating the VM but before finishing its configuration,
fix the reported incompatibility and rerun the same command with `RESUME=yes`.
This explicit switch prevents an existing VM from being modified accidentally;
the recovery path will grow an undersized disk but never shrink an existing one.

The generated installation includes Python, OpenSSH, and Avahi. After starting
the VM, bootstrap waits for key-based SSH authentication at `HOSTNAME.local`,
runs the complete playbook against a private temporary inventory, installs
Parallels Tools unattended, and reboots. It reports SSH progress every 30
seconds; the default timeout is 45 minutes. Temporary inventory and known-hosts
data are removed when the command exits, and the project files
remain free of the generated host and account details.

Override the target or timeout when mDNS is unavailable:

```bash
make bootstrap SSH_HOST=VM_IP_ADDRESS SSH_WAIT_TIMEOUT=3600
```

To stop after creating and starting the installed server, disable both the
provisioning stage and (optionally) the SSH wait:

```bash
make bootstrap RUN_ANSIBLE=no
make bootstrap RUN_ANSIBLE=no WAIT_FOR_SSH=no
```

Interactive installation requires `AUTOINSTALL=no RUN_ANSIBLE=no`.

## Inventory and variables

Replace both placeholders in `inventory.ini`:

```ini
[workstation]
ubuntu-vm ansible_host=YOUR_HOST_OR_IP ansible_user=YOUR_USER
```

Set the same account in `group_vars/all.yml`:

```yaml
workstation_user: YOUR_USER
```

The shell role creates the configurable `workstation_projects_dir`, which
defaults to `~/Development/Projects` for the workstation account.

The main switches live in `group_vars/all.yml`. Firefox, Chrome, VS Code, mise,
Claude Code, Docker, and Snap removal are enabled by default. Set
`remove_snapd: false` if the VM needs any snaps. Useful display settings include
`hyprland_scale`, `hyprland_main_modifier`, `keyboard_layout`, `ui_font_family`,
`ui_font_size`, and `ghostty_font_size`. The main modifier defaults to `ALT SUPER`, requiring
Option+Command together for Hyprland shortcuts in Parallels. Ghostty defaults
to scoped Mesa software rendering through `ghostty_force_software_rendering`
because Parallels virgl does not expose Ghostty's required OpenGL version.

The desktop role installs Ubuntu's `fonts-jetbrains-mono` package. It is the
primary Ghostty font and the configured face for Waybar, fuzzel, mako, and GTK
3/4 applications. Ghostty keeps `MesloLGS NF` as a fallback so the synced
Powerlevel10k configuration retains its Nerd Font symbols.

Before its first apt operation, the base role compares the VM's UTC clock with
the Ansible controller. If their difference exceeds
`maximum_clock_skew_seconds`, it corrects the guest and restarts chrony. This
prevents apt from rejecting signed repository metadata as not valid yet after
the VM has been suspended or restored.

Set `parallels_vm_name` to the VM's exact name in Parallels Desktop. With
`prepare_parallels_tools_media: true`, the playbook checks inside Ubuntu for
an installed `parallels-tools` package or Tools executable. Only when Tools is
absent does it ask the Mac's `prlctl` to attach the bundled ARM64 ISO. It reuses
an already attached or mounted Parallels Tools disc. Standalone playbook runs
leave the installer available for manual use by default; set
`install_parallels_tools_automatically: true` to use the vendor's unattended
installer. The full bootstrap workflow enables that setting automatically.

The shell role clones [Oh My Zsh](https://github.com/ohmyzsh/ohmyzsh) and
[Powerlevel10k](https://github.com/romkatv/powerlevel10k) into the workstation
user's standard directories. It keeps `.zshrc` Linux-specific and managed by
Ansible; it does not copy the controller's complete `.zshrc`. When available,
the role copies the controller's `.p10k.zsh` and MesloLGS NF fonts, controlled
by `sync_controller_powerlevel10k_config` and
`sync_controller_powerlevel10k_fonts`. Override the controller paths in
`group_vars/all.yml` when running the playbook from a different machine.

The shell role also conditionally copies the controller's `.gitconfig` and
`.gitconfig-higeia` without storing either file in the project. Missing files
are skipped. Control this with `sync_controller_git_config`,
`controller_git_config_dir`, and `controller_git_config_files`.

The shell role can also copy the controller's `~/.ssh/id_rsa` and matching
public key directly into the workstation user's `~/.ssh`, with `0700`
directory and `0600` private-key permissions. The key is read from the
controller only while Ansible runs and is never stored in this repository.
Control this with `sync_controller_ssh_key`, `controller_ssh_key_dir`, and
`controller_ssh_key_files`. This duplicates a private credential into the VM;
set the switch to `false` when agent forwarding or a dedicated VM key is
preferred.

The developer-apps role also conditionally copies these items from the
controller's `~/.claude`: `hooks/block-commands.sh`,
`statusline-command.sh`, `output-styles`, and `settings.json`.
Missing items are skipped. Files are copied with restrictive permissions and
`output-styles` is merged with its target rather than deleting VM-only content.
The controller home path in the hook is rewritten for the workstation account.
The `~/.claude/plugins` tree is deliberately not synchronized. Control this with
`sync_controller_claude_config` and the `controller_claude_*` variables in
`group_vars/all.yml`. The controller's personal files are never stored in this
project.

The playbook deliberately refuses to run unless the target reports Ubuntu 26.04
(Resolute) on `aarch64` and all placeholders have been replaced.

## Validate and run

From this directory, check connectivity and syntax:

```bash
ansible -i inventory.ini workstation -m ping
ansible-playbook -i inventory.ini site.yml --syntax-check
```

Provision with SSH keys:

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass
```

With SSH password authentication:

```bash
ansible-playbook -i inventory.ini site.yml --ask-pass --ask-become-pass
```

Roles are independently taggable. For example:

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass --tags shell,developer_apps
```

For a VM created by this project's bootstrap workflow, the Make target can
discover its address and build a private temporary inventory automatically:

```bash
make apply-playbook VM_NAME="Ubuntu Workstation"
```

The target starts the VM when necessary, prefers the IPv4 address reported by
Parallels, falls back to the normalized `.local` hostname, waits for key-based
SSH, and runs `site.yml` with `--ask-become-pass`. It defaults to the current
macOS username and the same preferred SSH-key order as bootstrap. Override
`GUEST_USER`, `SSH_HOST`, or `SSH_PUBLIC_KEY` when the VM was created with
non-default values.

Add playbook options with `PLAYBOOK_ARGS`; the default privilege-escalation
prompt remains in place:

```bash
make apply-playbook \
  VM_NAME="Ubuntu Workstation" \
  PLAYBOOK_ARGS="--tags desktop"
```

Set `BECOME_ARGS=` for a non-privileged operation such as `--syntax-check`.

To prepare only the Parallels Tools installation media when Tools is absent:

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass --tags parallels_tools
```

To synchronize only the selected Claude Code configuration:

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass --tags claude_config
```

To synchronize only the selected Git configuration:

```bash
ansible-playbook -i inventory.ini site.yml --ask-become-pass --tags git_config
```

To synchronize only the selected SSH key into a bootstrapped VM:

```bash
make apply-playbook \
  VM_NAME="Ubuntu Workstation" \
  PLAYBOOK_ARGS="--tags ssh_keys"
```

A standalone playbook run does not reboot by default. Reboot manually when
convenient, or set `reboot_after_provision: true`. The full bootstrap workflow
enables this setting, waits for the reboot, and returns only after the
workstation is reachable again.

## Parallels Tools

The base role installs `dkms`, `libelf-dev`, `build-essential`, `pkg-config`, and
headers for the running kernel. The `parallels_tools` role conditionally makes
the matching installer media accessible inside the VM. Full bootstrap runs the
bundled unattended installer; standalone playbook runs keep installation
manual by default.

After the role reports the installer path, run its `install` program with sudo.
For example, if the role mounted the image at its default location:

```bash
cd /media/cdrom0
sudo ./install
```

A VM snapshot immediately before this step is sensible.
If the kernel was upgraded by the playbook, reboot before installing the tools
so the running kernel and installed headers agree.

Wayland integration in Parallels can vary by Parallels Tools release. Test
dynamic resolution, shared clipboard, pointer behaviour, audio, and shared
folders before treating the VM as finished.

Parallels Tools publishes resized virtio display modes, but its Wayland display
client targets GNOME/Mutter rather than Hyprland. Parallels v27 and Ubuntu's
Hyprland 0.53 currently reject runtime modesets, including ordinary advertised
resolutions. The safe default is therefore a fixed `1920x1200@59.88` startup
mode, controlled by `parallels_hyprland_fixed_mode`. This gives the VM a useful
window size immediately after login without depending on a resize event.

With `enable_parallels_hyprland_integration: true`, clipboard and drag-and-drop
helpers remain Wayland-native. The incompatible combined Parallels autostart is
disabled. Set `parallels_dynamic_resolution_enabled: true` only to experiment
with the XWayland `prlcc` bridge; it is disabled by default because the current
virtio driver rejects the requested mode.

Parallels' virtio GPU currently rejects Aquamarine's atomic test commit when
Hyprland changes the framebuffer size. Although Aquamarine exposes a legacy
DRM path, `hyprland_use_legacy_drm` remains `false`: enabling it makes Ubuntu's
Hyprland 0.53 session exit during startup on Parallels v27. A failed dynamic
resize is preferable to a graphical login loop. Changing this experimental
setting requires a new graphical login (or a reboot).

Verify the fixed mode and the enabled integration helpers inside the guest:

```bash
hyprctl monitors all
systemctl --user status parallels-prlcp-wayland.service
systemctl --user status parallels-prldnd-wayland.service
```

When experimenting with dynamic resolution, inspect its services with
`systemctl --user status parallels-prlcc-x11.service` and
`systemctl --user status parallels-dynamic-resolution.service`.

## Software ownership boundary

Ubuntu's package manager owns durable workstation software: Hyprland and its
desktop services, browsers, VS Code, Docker, shells, editors, CLI utilities, and
mise itself. Claude Code is the deliberate exception: its vendor-recommended
native installer owns that application and its updates.

Oh My Zsh and Powerlevel10k are treated as user-shell configuration rather
than workstation software. The shell role manages their Git checkouts and
disables Oh My Zsh's independent updater.

mise owns rapidly changing developer runtimes and toolchains such as Node.js,
Ruby, Python, Go, Terraform/OpenTofu, and project-specific utilities. Do not add
those runtimes to the base or shell roles. Declare them per project in
`mise.toml`, for example:

```toml
[tools]
node = "24"
ruby = "4"
python = "3.14"
```

This keeps the operating system boring and stable while projects select the
toolchain versions they need.

## Default Hyprland keys

| Keys | Action |
| --- | --- |
| `ALT+SUPER+Enter` | Ghostty |
| `ALT+SUPER+Space` | fuzzel launcher |
| `ALT+SUPER+B` | Google Chrome |
| `ALT+SUPER+Shift+B` | Firefox |
| `ALT+SUPER+C` | Visual Studio Code |
| `ALT+SUPER+E` | Nautilus |
| `ALT+SUPER+P` | Clipboard history |
| `ALT+SUPER+Shift+S` | Select area and copy screenshot |
| `ALT+SUPER+L` | Lock session |
| `ALT+SUPER+1..9` | Select workspace |
| `ALT+SUPER+Shift+1..9` | Move window to workspace |
